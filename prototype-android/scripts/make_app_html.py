"""Turn the vault prototype (browser preview) into the in-app page used by the Android shell."""
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
css = """
/* ---------- installed app mode (Android shell) ---------- */
html.inapp, html.inapp body{height:100%;overflow:hidden;background:var(--surface)}
html.inapp .stagebar{display:none}
html.inapp .stage{padding:0;gap:0;height:100%;min-height:0}
html.inapp .device{width:100%;height:auto;flex:1;min-height:0;max-width:none;border-radius:0;box-shadow:none}
html.inapp .appbanner{display:block;align-self:stretch}
.appbanner{display:none;background:var(--warn-wash);color:var(--warn);font-size:12px;font-weight:600;text-align:center;padding:4px 8px}
"""
def rep(a, b):
    global s
    assert a in s, a[:60]
    s = s.replace(a, b, 1)
rep("</style>", css + "</style>")
rep("</head>", "<script>if(location.hostname==='appassets.androidplatform.net'){document.documentElement.classList.add('inapp');}</script>\n</head>")
rep('if(window.innerWidth<800){ device.className="device fit";',
    'if(document.documentElement.classList.contains("inapp")){ device.className="device fit"; } else if(window.innerWidth<800){ device.className="device fit";')
rep('<div class="device tablet" id="device">',
    '<div class="appbanner" role="note">Prototype · data stays on this device</div>\n  <div class="device tablet" id="device">')
open(dst, "w", encoding="utf-8").write(s)
print("wrote", dst)
