import CoreGraphics
import Foundation

#if canImport(llama)
    import llama
#endif

/// An LFM3 model the phone can run (GGUF from Hugging Face, downloaded on first use).
struct ModelSpec: Sendable, Identifiable {
    let id: String
    let repo: String
    let file: String
    let bytes: Int64
    /// Vision projector, for VL models.
    let mmproj: String?
    let mmprojBytes: Int64

    var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    var mmprojURL: URL? { mmproj.map { URL(string: "https://huggingface.co/\(repo)/resolve/main/\($0)")! } }
    var vision: Bool { mmproj != nil }

    /// The official Quantization-Aware-Distilled Q4_0 builds: Q4_0 gets llama.cpp's repacked Arm kernels (fastest on
    /// the A16), and QAD training recovers the accuracy plain Q4_0 loses. ~1 GB each, so they fit a 6 GB phone.
    static let all: [ModelSpec] = [
        ModelSpec(
            id: "lfm3-1.7b", repo: "LiquidAI/LFM3-1.7B-GGUF", file: "LFM3-1.7B-QAD-Q4_0.gguf", bytes: 1_050_000_000,
            mmproj: nil, mmprojBytes: 0),
        ModelSpec(
            id: "lfm3-vl-2b", repo: "LiquidAI/LFM3-VL-2B-GGUF", file: "LFM3-VL-2B-QAD-Q4_0.gguf",
            bytes: 1_050_000_000, mmproj: "mmproj-LFM3-VL-2B-Q8_0.gguf", mmprojBytes: 200_000_000),
    ]
    static func named(_ id: String) -> ModelSpec? { all.first { $0.id == id } }
}

/// Runs LFM3 on the phone with llama.cpp (Metal). One model is loaded at a time; every call runs on one serial queue
/// because llama.cpp contexts are not thread-safe. Device builds only: the llama.cpp release has no Simulator slice.
final class LocalModel: @unchecked Sendable {
    struct Options: Sendable {
        var maxTokens = 256
        /// LFM3 thinks before answering by default (`<think>…</think>`); off is much faster for short robot tasks.
        var thinking = false
        /// Metal GPU, or the CPU (llama.cpp repacks Q4_0 into Arm-optimized kernels there).
        var gpu = true
        /// Stop generating after this long, so the caller (the bridge waits 180 s) gets an answer, not a timeout.
        var timeLimit: TimeInterval = 150
    }

    struct Output: Sendable {
        let text: String
        let thinking: String?
        let model: String
        let backend: String
        let promptTokens: Int
        let generatedTokens: Int
        let prefillTokensPerSecond: Double
        let decodeTokensPerSecond: Double
        let loadSeconds: Double
        let totalSeconds: Double
    }

    enum Failure: Error, CustomStringConvertible {
        case notDownloaded(String)
        case unavailable
        case loadFailed(String)
        case tooLong
        case generation(String)
        case busy, tooHot
        var description: String {
            switch self {
            case .notDownloaded(let m): "\(m) is not downloaded yet: run phone_model_download first"
            case .unavailable: "llama.cpp is not in this build (Simulator)"
            case .loadFailed(let m): "could not load \(m)"
            case .tooLong: "prompt too long for the 4096-token context"
            case .generation(let e): "generation failed: \(e)"
            case .busy: "the phone's model is busy with another request"
            case .tooHot: "the phone is too hot to run a model right now"
            }
        }
    }

    static let contextTokens: UInt32 = 4096
    #if canImport(llama)
        static let available = true
    #else
        static let available = false
    #endif
    static let dir: URL = {
        let d = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        var dd = d
        try? dd.setResourceValues(v)
        return d
    }()

    let downloads = Downloads()
    private let queue = DispatchQueue(label: "llm", qos: .userInitiated)
    private let lock = NSLock()
    private var _loaded: String?
    private var _busy = false
    var loaded: String? { lock.withLock { _loaded } }

    static func path(_ file: String) -> URL { dir.appending(path: file) }
    static func isDownloaded(_ m: ModelSpec) -> Bool {
        FileManager.default.fileExists(atPath: path(m.file).path)
            && (m.mmproj.map { FileManager.default.fileExists(atPath: path($0).path) } ?? true)
    }

    /// Starts (or joins) the download of a model's files. Progress is in `downloads`.
    func download(_ m: ModelSpec) {
        downloads.fetch(m.url, to: Self.path(m.file), expected: m.bytes)
        if let u = m.mmprojURL, let f = m.mmproj { downloads.fetch(u, to: Self.path(f), expected: m.mmprojBytes) }
    }

    func delete(_ m: ModelSpec) {
        unload()
        try? FileManager.default.removeItem(at: Self.path(m.file))
        if let f = m.mmproj { try? FileManager.default.removeItem(at: Self.path(f)) }
    }

    /// A chat turn: role is system, user or assistant.
    typealias Message = (role: String, content: String)

    /// Generate the next assistant turn. `image` (RGB bytes) goes with the last user message (vision models only).
    func generate(
        model m: ModelSpec, messages: [Message], image: (rgb: [UInt8], width: Int, height: Int)?, options: Options
    ) async throws -> Output {
        guard Self.isDownloaded(m) else { throw Failure.notDownloaded(m.id) }
        guard claim() else { throw Failure.busy }
        defer { lock.withLock { _busy = false } }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result { try self.run(m, messages, image, options) })
            }
        }
    }

    private func claim() -> Bool {
        lock.withLock {
            if _busy { return false }
            _busy = true
            return true
        }
    }

    func unload() {
        queue.async { self.free() }
    }

    /// Load `m` in the background so the first request doesn't pay for it (llama.cpp compiles its Metal shaders on
    /// the first load in each launch, ~25 s on the A16).
    func warmUp(_ m: ModelSpec) {
        guard Self.isDownloaded(m) else { return }
        queue.async { _ = try? self.load(m, gpu: true) }
    }

    #if canImport(llama)
        private var model: OpaquePointer?
        private var ctx: OpaquePointer?
        private var mctx: OpaquePointer?
        private static let backend: Void = { llama_backend_init() }()

        private func free() {
            if let mctx { mtmd_free(mctx) }
            if let ctx { llama_free(ctx) }
            if let model { llama_model_free(model) }
            mctx = nil
            ctx = nil
            model = nil
            lock.withLock { _loaded = nil }
        }

        /// Loads `m` if it isn't already (on this backend). Returns the seconds it took (0 when already loaded).
        private func load(_ m: ModelSpec, gpu: Bool) throws -> Double {
            let key = gpu ? m.id : "\(m.id) (cpu)"
            if loaded == key { return 0 }
            free()
            _ = Self.backend
            let t0 = Date()
            var mp = llama_model_default_params()
            mp.n_gpu_layers = gpu ? 99 : 0  // all layers on Metal, or none
            guard let model = llama_model_load_from_file(Self.path(m.file).path, mp) else {
                throw Failure.loadFailed(m.id)
            }
            var cp = llama_context_default_params()
            cp.n_ctx = Self.contextTokens
            cp.n_batch = 512
            cp.n_ubatch = 512
            cp.n_threads = 4  // A16: 2 performance + 4 efficiency cores; Metal does the heavy lifting
            cp.n_threads_batch = 4
            guard let ctx = llama_init_from_model(model, cp) else {
                llama_model_free(model)
                throw Failure.loadFailed(m.id)
            }
            self.model = model
            self.ctx = ctx
            if let proj = m.mmproj {
                var p = mtmd_context_params_default()
                p.use_gpu = gpu
                p.n_threads = 4
                p.print_timings = false
                mctx = mtmd_init_from_file(Self.path(proj).path, model, p)
                if mctx == nil {
                    free()
                    throw Failure.loadFailed("\(m.id) vision projector")
                }
            }
            lock.withLock { _loaded = key }
            return Date().timeIntervalSince(t0)
        }

        /// LFM3 chat format (ChatML-style), ending with an open assistant turn. BOS is added by tokenization.
        /// `media` is put at the start of the last user message. Without thinking, the assistant turn starts with an
        /// empty think block, as the model's own template does for `enable_thinking=false`.
        private static func chat(_ messages: [Message], media: String? = nil, thinking: Bool) -> String {
            let lastUser = messages.lastIndex { $0.role == "user" }
            var s = ""
            for (i, m) in messages.enumerated() where !m.content.isEmpty || i == lastUser {
                let content = i == lastUser ? (media.map { $0 + "\n" } ?? "") + m.content : m.content
                s += "<|im_start|>\(m.role)\n\(content)<|im_end|>\n"
            }
            return s + "<|im_start|>assistant\n" + (thinking ? "<think>" : "<think></think>")
        }

        private func run(
            _ m: ModelSpec, _ messages: [Message], _ image: (rgb: [UInt8], width: Int, height: Int)?,
            _ options: Options
        ) throws -> Output {
            let t0 = Date()
            let maxTokens = options.maxTokens
            let loadSeconds = try load(m, gpu: options.gpu)
            guard let ctx, let model else { throw Failure.loadFailed(m.id) }
            let vocab = llama_model_get_vocab(model)
            llama_memory_clear(llama_get_memory(ctx), true)

            let tPrefill = Date()
            var nPast: llama_pos = 0
            var promptTokens = 0
            if let image, let mctx {
                let marker = String(cString: mtmd_default_marker())
                let text = Self.chat(messages, media: marker, thinking: options.thinking)
                guard
                    let bmp = image.rgb.withUnsafeBufferPointer({
                        mtmd_bitmap_init(UInt32(image.width), UInt32(image.height), $0.baseAddress)
                    })
                else { throw Failure.generation("bad image") }
                defer { mtmd_bitmap_free(bmp) }
                guard let chunks = mtmd_input_chunks_init() else { throw Failure.generation("no chunks") }
                defer { mtmd_input_chunks_free(chunks) }
                let rc: Int32 = text.withCString { cs in
                    var input = mtmd_input_text(text: cs, text_len: strlen(cs), add_special: true, parse_special: true)
                    var bitmaps: [OpaquePointer?] = [bmp]
                    return bitmaps.withUnsafeMutableBufferPointer { bp in
                        mtmd_tokenize(mctx, chunks, &input, bp.baseAddress, 1)
                    }
                }
                guard rc == 0 else { throw Failure.generation("image tokenize \(rc)") }
                promptTokens = Int(mtmd_helper_get_n_tokens(chunks))
                guard promptTokens + maxTokens < Int(Self.contextTokens) else { throw Failure.tooLong }
                guard mtmd_helper_eval_chunks(mctx, ctx, chunks, 0, 0, 512, true, &nPast) == 0 else {
                    throw Failure.generation("image eval")
                }
            } else {
                var tokens = Self.tokenize(vocab, Self.chat(messages, thinking: options.thinking))
                promptTokens = tokens.count
                guard promptTokens + maxTokens < Int(Self.contextTokens) else { throw Failure.tooLong }
                var i = 0
                while i < tokens.count {
                    let n = min(512, tokens.count - i)
                    let rc = tokens.withUnsafeMutableBufferPointer { p in
                        llama_decode(ctx, llama_batch_get_one(p.baseAddress! + i, Int32(n)))
                    }
                    guard rc == 0 else { throw Failure.generation("decode \(rc)") }
                    i += n
                }
                nPast = llama_pos(tokens.count)
            }
            let prefillSeconds = Date().timeIntervalSince(tPrefill)

            // Liquid's recommended sampling for LFM3: temperature 0.1, top-k 50, repeat penalty 1.1.
            let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())!
            defer { llama_sampler_free(smpl) }
            llama_sampler_chain_add(smpl, llama_sampler_init_top_k(50))
            llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
            llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.1))
            llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

            let tDecode = Date()
            var bytes: [UInt8] = []
            var generated = 0
            var token = llama_sampler_sample(smpl, ctx, -1)
            let deadline = t0.addingTimeInterval(options.timeLimit)
            while generated < maxTokens, !llama_vocab_is_eog(vocab, token), Date() < deadline {
                bytes += Self.piece(vocab, token)
                generated += 1
                var t = token
                guard llama_decode(ctx, llama_batch_get_one(&t, 1)) == 0 else { break }
                token = llama_sampler_sample(smpl, ctx, -1)
            }
            _ = nPast
            let decodeSeconds = Date().timeIntervalSince(tDecode)
            var text = String(decoding: bytes, as: UTF8.self)
            var thought: String?
            if let end = text.range(of: "</think>") {
                thought = String(text[..<end.lowerBound]).replacingOccurrences(of: "<think>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                text = String(text[end.upperBound...])
            } else if options.thinking {
                thought = text  // ran out of tokens while still thinking
                text = ""
            }
            return Output(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), thinking: thought, model: m.id,
                backend: options.gpu ? "metal" : "cpu", promptTokens: promptTokens, generatedTokens: generated,
                prefillTokensPerSecond: Double(promptTokens) / max(prefillSeconds, 1e-6),
                decodeTokensPerSecond: Double(generated) / max(decodeSeconds, 1e-6), loadSeconds: loadSeconds,
                totalSeconds: Date().timeIntervalSince(t0))
        }

        private static func tokenize(_ vocab: OpaquePointer?, _ text: String) -> [llama_token] {
            let utf8 = Array(text.utf8CString)
            var out = [llama_token](repeating: 0, count: utf8.count + 8)
            var n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), true, true)
            if n < 0 {
                out = [llama_token](repeating: 0, count: Int(-n))
                n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), true, true)
            }
            return Array(out.prefix(Int(max(0, n))))
        }

        private static func piece(_ vocab: OpaquePointer?, _ token: llama_token) -> [UInt8] {
            var buf = [CChar](repeating: 0, count: 64)
            var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            if n < 0 {
                buf = [CChar](repeating: 0, count: Int(-n))
                n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            }
            return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
        }
    #else
        private func free() {}
        private func load(_ m: ModelSpec, gpu: Bool) throws -> Double { throw Failure.unavailable }
        private func run(
            _ m: ModelSpec, _ messages: [Message], _ image: (rgb: [UInt8], width: Int, height: Int)?,
            _ options: Options
        ) throws -> Output { throw Failure.unavailable }
    #endif
}

/// Model downloads with progress (foreground session: the mounted app is always in front).
final class Downloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        var received: Int64
        var expected: Int64
        var error: String?
    }

    private let lock = NSLock()
    private var progress: [URL: Progress] = [:]
    private var destinations: [Int: URL] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Received / expected bytes and the last error for each file still downloading or failed.
    func snapshot() -> [String: Progress] {
        lock.withLock { Dictionary(uniqueKeysWithValues: progress.map { ($0.key.lastPathComponent, $0.value) }) }
    }

    func fetch(_ url: URL, to dest: URL, expected: Int64) {
        if FileManager.default.fileExists(atPath: dest.path) { return }
        let start: Bool = lock.withLock {
            if let p = progress[dest], p.error == nil { return false }  // already running
            progress[dest] = Progress(received: 0, expected: expected)
            return true
        }
        guard start else { return }
        let task = session.downloadTask(with: url)
        lock.withLock { destinations[task.taskIdentifier] = dest }
        task.resume()
    }

    func urlSession(
        _ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64,
        totalBytesExpectedToWrite e: Int64
    ) {
        lock.withLock {
            guard let d = destinations[t.taskIdentifier] else { return }
            progress[d]?.received = w
            if e > 0 { progress[d]?.expected = e }
        }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let d = lock.withLock({ destinations[t.taskIdentifier] }) else { return }
        if let http = t.response as? HTTPURLResponse, http.statusCode != 200 {
            lock.withLock { progress[d]?.error = "HTTP \(http.statusCode)" }
            return
        }
        do {
            try? FileManager.default.removeItem(at: d)
            try FileManager.default.moveItem(at: location, to: d)
            lock.withLock { progress[d] = nil }
        } catch {
            lock.withLock { progress[d]?.error = "\(error.localizedDescription)" }
        }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.withLock {
            if let d = destinations[t.taskIdentifier] { progress[d]?.error = error.localizedDescription }
        }
    }
}
