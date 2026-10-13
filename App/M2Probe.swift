import Foundation

/// M2 探针页的素材与承载目录的物料。
///
/// 素材由端侧自带(pro:「素材各端自己写，不互相复制」),这里把入口 HTML、一个脚本、一张图在启动时
/// **落到磁盘的承载目录**里,越界目标文件落在承载目录**之外**。落到磁盘而不是直接读 app bundle,是为了让
/// 「承载目录」与「目录之外」在磁盘上有确定的父子关系 —— `escape-encoded` 那条要试的就是编码 `..` 能不能
/// 爬出承载目录,目录边界得是真实的。
///
/// 规约(拦截标记 `INTERCEPTED`、越界标记 `OUT_OF_BOUNDS`、断言清单与顺序)三端一字不差,在 pro 的
/// M2 最后一节,本仓不自定。
enum M2Probe {
    /// 页面侧把六条断言的结果落到这个全局;原生侧 `evaluateJavaScript` 回读。
    static let resultGlobal = "window.__CRAB_PROBE__"
    static let doneGlobal = "window.__CRAB_PROBE_DONE__"

    /// 原生侧把判定结果写到 Documents 下这个文件,`scripts/probe.sh` 按这个名字回读。
    static let resultFileName = "m2-probe.txt"

    /// M2 的六条 slug,顺序即 pro 文档顺序,输出与回读都按它。
    static let slugs = ["origin", "storage", "subresource", "intercept", "escape", "escape-encoded"]

    /// 承载目录(根)。放在 Documents/hosting 下。
    static func hostingRoot() -> URL {
        documents().appendingPathComponent("hosting", isDirectory: true)
    }

    /// 承载目录之外的越界目标文件。放在 Documents 下(hosting 的父目录),naive 的 `hosting/../out-of-bounds.txt`
    /// 正好会命中它 —— handler 归一化没做对就会把它漏出去。
    static func outOfBoundsFile() -> URL {
        documents().appendingPathComponent("out-of-bounds.txt")
    }

    private static func documents() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 把素材落到磁盘。每次启动重写一遍,保证内容是当前这一版。
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
        // 越界目标:承载目录之外,内容是固定标记。
        try Data("OUT_OF_BOUNDS\n".utf8).write(to: outOfBoundsFile())
    }

    /// 子资源之一:一段脚本,加载成功就把标记置上。
    static let probeJS = "window.__CRAB_SUB_JS__ = true;"

    /// 子资源之二:一张 1x1 的 PNG(定长字节,解码即得,不依赖 bundle)。
    static let probePNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
}

extension M2Probe {
    /// 入口 HTML:六条断言在页面侧自判,结果落 `window.__CRAB_PROBE__`,跑完置 `__CRAB_PROBE_DONE__`。
    /// 判法严格照 pro 的 M2「怎么算过」那张表,一字不差地对应六个 slug。
    static let indexHTML = #"""
    <!doctype html>
    <html lang="zh-Hans">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="probe.js"></script>
    <style>body{font:13px -apple-system;margin:10px}#out{white-space:pre}</style>
    </head>
    <body>
    <h3>M2 · 本地承载探针</h3>
    <img id="probe-img" src="probe.png" width="8" height="8" alt="">
    <pre id="out">running…</pre>
    <script>
    (async function () {
      var r = {};

      // origin:非 null、非空字符串
      r['origin'] = (location.origin && location.origin !== 'null') ? 'PASS' : 'FAIL';

      // storage:setItem / getItem 往返
      try {
        localStorage.setItem('crab-probe', 'ok');
        r['storage'] = (localStorage.getItem('crab-probe') === 'ok') ? 'PASS' : 'FAIL';
        localStorage.removeItem('crab-probe');
      } catch (e) { r['storage'] = 'FAIL'; }

      // subresource:同 origin 的一个脚本 + 一张图都加载成功
      var img = document.getElementById('probe-img');
      var imgOK = await new Promise(function (res) {
        if (img.complete) return res(img.naturalWidth > 0);
        img.onload = function () { res(img.naturalWidth > 0); };
        img.onerror = function () { res(false); };
      });
      r['subresource'] = (window.__CRAB_SUB_JS__ === true && imgOK) ? 'PASS' : 'FAIL';

      // intercept:承载 origin 上一个不存在的路径,读到拦截点的固定标记
      try {
        var t = await (await fetch('does-not-exist-' + Date.now())).text();
        r['intercept'] = t.indexOf('INTERCEPTED') >= 0 ? 'PASS' : 'FAIL';
      } catch (e) { r['intercept'] = 'FAIL'; }

      // escape:明文 ../,响应体不含越界标记即算拦住
      try {
        var e1 = await (await fetch('../out-of-bounds.txt')).text();
        r['escape'] = e1.indexOf('OUT_OF_BOUNDS') >= 0 ? 'FAIL' : 'PASS';
      } catch (e) { r['escape'] = 'PASS'; }

      // escape-encoded:编码 %2e%2e%2f,判法同上
      try {
        var e2 = await (await fetch('%2e%2e%2fout-of-bounds.txt')).text();
        r['escape-encoded'] = e2.indexOf('OUT_OF_BOUNDS') >= 0 ? 'FAIL' : 'PASS';
      } catch (e) { r['escape-encoded'] = 'PASS'; }

      window.__CRAB_PROBE__ = r;
      window.__CRAB_PROBE_DONE__ = true;
      document.getElementById('out').textContent =
        ['origin','storage','subresource','intercept','escape','escape-encoded']
          .map(function (k) { return k + ' ' + r[k]; }).join('\n');
    })();
    </script>
    </body>
    </html>
    """#
}

