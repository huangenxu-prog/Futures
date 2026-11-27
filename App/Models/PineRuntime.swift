import Foundation
import JavaScriptCore

// Experimental local runtime; not wired into the production chart yet.
struct PineRuntimeBar: Encodable, Sendable {
    let open, high, low, close, volume: Double
    let openTime, closeTime: Int64
}

struct PineRuntimePoint: Decodable, Sendable {
    let time: Double?
    let value: Double?
}

struct PineRuntimePlot: Decodable, Sendable {
    let name: String
    let points: [PineRuntimePoint]
}

enum PineRuntimeError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

enum PineRuntime {
    // Execute on a dedicated background thread. The context must not be shared
    // across concurrent evaluations. No native capabilities are exposed to JS.
    static func evaluate(source: String, bars: [PineRuntimeBar], bundleSource: String) async throws -> [PineRuntimePlot] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try run(source: source, bars: bars, bundleSource: bundleSource)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func run(source: String, bars: [PineRuntimeBar], bundleSource: String) throws -> [PineRuntimePlot] {
        guard source.utf8.count <= 100_000, !bars.isEmpty, bars.count <= 10_000 else {
            throw PineRuntimeError.failed("公式或行情数据超出实验限制")
        }
        guard let context = JSContext() else { throw PineRuntimeError.failed("JavaScriptCore 初始化失败") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "JavaScript exception" }
        context.evaluateScript(#"""
if (typeof globalThis.TextEncoder === 'undefined') {
  globalThis.TextEncoder = class {
    get encoding() { return 'utf-8'; }
    encode(input = '') {
      const bytes = [];
      for (const ch of String(input)) {
        let cp = ch.codePointAt(0);
        if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD;
        if (cp < 0x80) bytes.push(cp);
        else if (cp < 0x800) bytes.push(0xC0 | (cp >> 6), 0x80 | (cp & 63));
        else if (cp < 0x10000) bytes.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        else bytes.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      }
      return Uint8Array.from(bytes);
    }
  };
  const encoded = new TextEncoder().encode('A中😀');
  if (Array.from(encoded).join(',') !== '65,228,184,173,240,159,152,128') throw new Error('UTF-8 encoder self-test failed');
}
if (typeof globalThis.AbortController === 'undefined') {
  class LocalAbortSignal {
    constructor() { this.aborted = false; this.reason = undefined; this.onabort = null; this.listeners = new Map(); }
    addEventListener(type, fn, options) {
      if (type === 'abort' && fn && !this.listeners.has(fn)) this.listeners.set(fn, !!(options && options.once));
    }
    removeEventListener(type, fn) { if (type === 'abort') this.listeners.delete(fn); }
    throwIfAborted() { if (this.aborted) throw this.reason; }
  }
  class LocalAbortController {
    constructor() { this.signal = new LocalAbortSignal(); }
    abort(reason) {
      const s = this.signal;
      if (s.aborted) return;
      s.aborted = true;
      s.reason = reason === undefined ? Object.assign(new Error('Aborted'), {name:'AbortError'}) : reason;
      const event = {type:'abort', target:s, currentTarget:s};
      for (const [fn, once] of Array.from(s.listeners)) {
        if (once) s.listeners.delete(fn);
        if (typeof fn === 'function') fn.call(s,event); else fn.handleEvent(event);
      }
      if (typeof s.onabort === 'function') s.onabort.call(s,event);
    }
  }
  globalThis.AbortSignal = LocalAbortSignal;
  globalThis.AbortController = LocalAbortController;
  const c = new AbortController();
  let calls = 0;
  c.signal.addEventListener('abort', () => calls++, {once:true});
  c.abort(); c.abort();
  if (!c.signal.aborted || calls !== 1) throw new Error('Cancellation shim self-test failed');
}
"""#)
        if let failure { throw PineRuntimeError.failed(failure) }
        context.evaluateScript(bundleSource)
        if let failure { throw PineRuntimeError.failed(failure) }
        let encoder = JSONEncoder()
        let json = String(decoding: try encoder.encode(bars), as: UTF8.self)
        context.setObject(json, forKeyedSubscript: "qihuiBarsJSON" as NSString)
        context.setObject(source, forKeyedSubscript: "qihuiSource" as NSString)
        context.evaluateScript(#"""
        var qihuiResult = null, qihuiError = null;
        (async function() {
          try {
            const pine = new PineTS(JSON.parse(qihuiBarsJSON));
            const {plots} = await pine.run(qihuiSource);
            qihuiResult = JSON.stringify(Object.entries(plots)
              .filter(([key]) => !key.startsWith("__"))
              .map(([name, series]) => ({
                name,
                points: series.data.map(p => ({
                  time: typeof p.time === "number" && Number.isFinite(p.time) ? p.time : null,
                  value: typeof p.value === "number" && Number.isFinite(p.value) ? p.value : null
                }))
              })));
          } catch (e) { qihuiError = String(e); }
        })();
        """#)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let failure { throw PineRuntimeError.failed(failure) }
            if let error = context.objectForKeyedSubscript("qihuiError"), !error.isNull, !error.isUndefined {
                throw PineRuntimeError.failed(error.toString() ?? "PineTS error")
            }
            if let result = context.objectForKeyedSubscript("qihuiResult"), !result.isNull, !result.isUndefined,
               let json = result.toString() {
                return try JSONDecoder().decode([PineRuntimePlot].self, from: Data(json.utf8))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        throw PineRuntimeError.failed("PineTS 异步结果超时")
    }
}
