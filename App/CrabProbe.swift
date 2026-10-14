import Foundation

/// 探针页的素材与承载目录的物料。M2 装六条断言,M3 在同一张页面上加 `inject-order` / `inject-scope`
/// 两条,外加一行打印(`typeof localStorage` 与 `navigator.userAgent`,供人工比对)。
///
/// 素材由端侧自带(pro:「素材各端自己写，不互相复制」),启动时落到磁盘的承载目录,越界目标落在
/// 承载目录**之外** —— `escape-encoded` 要试编码 `..` 能不能爬出承载目录,目录边界得是真实的。
/// 规约(`INTERCEPTED` / `OUT_OF_BOUNDS` 标记、断言清单与顺序)三端一字不差,在 pro 的 M2 最后一节。
enum CrabProbe {
    static let resultGlobal = "window.__CRAB_PROBE__"
    static let uaGlobal = "window.__CRAB_PROBE_UA__"
    static let lsGlobal = "window.__CRAB_PROBE_LS__"
    static let persistGlobal = "window.__CRAB_PROBE_PERSIST__"
    static let doneGlobal = "window.__CRAB_PROBE_DONE__"

    /// 原生侧把结果写到 Documents 下这个文件,`scripts/probe.sh` 按这个名字回读。
    static let resultFileName = "probe-result.txt"

    /// 已实现的 slug,顺序即 pro 文档顺序。M4 八条还没接,不在这里。
    static let slugs = [
        "origin", "storage", "subresource", "intercept", "escape", "escape-encoded",
        "inject-order", "inject-scope",
    ]

    static func hostingRoot() -> URL {
        documents().appendingPathComponent("hosting", isDirectory: true)
    }

    static func outOfBoundsFile() -> URL {
        documents().appendingPathComponent("out-of-bounds.txt")
    }

    private static func documents() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 把素材落到磁盘。每次启动重写,保证是当前这一版。
    static func materialize() throws {
        let fm = FileManager.default
        let root = hostingRoot()
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try Data(indexHTML.utf8).write(to: root.appendingPathComponent("index.html"))
        try Data(probeJS.utf8).write(to: root.appendingPathComponent("probe.js"))
        if let png = Data(base64Encoded: probePNGBase64) {
            try png.write(to: root.appendingPathComponent("probe.png"))
        }
        try Data("OUT_OF_BOUNDS\n".utf8).write(to: outOfBoundsFile())
    }

    /// 子资源之一:一段脚本,加载成功置标记。
    static let probeJS = "window.__CRAB_SUB_JS__ = true;"

    /// 子资源之二:一张 1x1 PNG(定长字节,不依赖 bundle)。
    static let probePNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
}

extension CrabProbe {
    /// 入口 HTML。八条断言在页面侧自判,结果落 `window.__CRAB_PROBE__`,UA / `typeof localStorage`
    /// 单独落两个全局,跑完置 `__CRAB_PROBE_DONE__`。判法严格照 pro 的 M2 / M3「怎么算过」。
    ///
    /// 顺序要紧:**首行脚本**抢在页面别的脚本之前读 `window.__CRAB__`,这就是 `inject-order` 的判据
    /// (注入早于页面首行、且 `injected === 1`)。
    static let indexHTML = #"""
    <!doctype html>
    <html lang="zh-Hans">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script>
      // inject-order:页面自身首行脚本读注入标记。存在且 injected===1 即成立。
      window.__INJECT_ORDER__ =
        (window.__CRAB__ && window.__CRAB__.injected === 1) ? 'PASS' : 'FAIL';
      // inject-scope:opaque 子帧经 postMessage 自报 typeof window.__CRAB__,这里先挂好收集。
      window.__scopeReports__ = [];
      addEventListener('message', function (e) {
        if (e.data && typeof e.data.scope !== 'undefined') {
          window.__scopeReports__.push(e.data.scope);
        }
      });
    </script>
    <script src="probe.js"></script>
    <style>body{font:13px -apple-system;margin:10px}#out{white-space:pre}iframe{width:1px;height:1px;border:0}</style>
    </head>
    <body>
    <h3>M2/M3 探针</h3>
    <img id="probe-img" src="probe.png" width="8" height="8" alt="">
    <iframe src="data:text/html,<script>parent.postMessage({scope:typeof window.__CRAB__},'*')</script>"></iframe>
    <pre id="out">running…</pre>
    <script>
    (async function () {
      var r = {};
      r['origin'] = (location.origin && location.origin !== 'null') ? 'PASS' : 'FAIL';

      try {
        localStorage.setItem('crab-probe', 'ok');
        r['storage'] = (localStorage.getItem('crab-probe') === 'ok') ? 'PASS' : 'FAIL';
        localStorage.removeItem('crab-probe');
      } catch (e) { r['storage'] = 'FAIL'; }

      // 跨会话留存:读一个不删的键 —— 本次启动前就在,说明带 identifier 的持久化 store 跨启动保住了。
      try {
        var had = localStorage.getItem('__crab_persist__');
        window.__CRAB_PROBE_PERSIST__ = had ? 'present' : 'absent';
        localStorage.setItem('__crab_persist__', 'v1');
      } catch (e) { window.__CRAB_PROBE_PERSIST__ = 'throw'; }

      var img = document.getElementById('probe-img');
      var imgOK = await new Promise(function (res) {
        if (img.complete) return res(img.naturalWidth > 0);
        img.onload = function () { res(img.naturalWidth > 0); };
        img.onerror = function () { res(false); };
      });
      r['subresource'] = (window.__CRAB_SUB_JS__ === true && imgOK) ? 'PASS' : 'FAIL';

      try {
        var t = await (await fetch('does-not-exist-' + Date.now())).text();
        r['intercept'] = t.indexOf('INTERCEPTED') >= 0 ? 'PASS' : 'FAIL';
      } catch (e) { r['intercept'] = 'FAIL'; }

      try {
        var e1 = await (await fetch('../out-of-bounds.txt')).text();
        r['escape'] = e1.indexOf('OUT_OF_BOUNDS') >= 0 ? 'FAIL' : 'PASS';
      } catch (e) { r['escape'] = 'PASS'; }

      try {
        var e2 = await (await fetch('%2e%2e%2fout-of-bounds.txt')).text();
        r['escape-encoded'] = e2.indexOf('OUT_OF_BOUNDS') >= 0 ? 'FAIL' : 'PASS';
      } catch (e) { r['escape-encoded'] = 'PASS'; }

      r['inject-order'] = window.__INJECT_ORDER__ || 'FAIL';

      var scope = await new Promise(function (res) {
        var t0 = Date.now();
        (function check() {
          if (window.__scopeReports__.length) return res(window.__scopeReports__[0]);
          if (Date.now() - t0 > 3000) return res('timeout');
          setTimeout(check, 50);
        })();
      });
      r['inject-scope'] = (scope === 'undefined') ? 'PASS' : 'FAIL';

      window.__CRAB_PROBE__ = r;
      window.__CRAB_PROBE_UA__ = navigator.userAgent;
      window.__CRAB_PROBE_LS__ = typeof localStorage;
      window.__CRAB_PROBE_DONE__ = true;
      document.getElementById('out').textContent =
        ['origin','storage','subresource','intercept','escape','escape-encoded','inject-order','inject-scope']
          .map(function (k) { return k + ' ' + r[k]; }).join('\n')
        + '\nua ' + navigator.userAgent + '\nlocalStorage ' + (typeof localStorage);
    })();
    </script>
    </body>
    </html>
    """#
}

