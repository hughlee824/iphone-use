extension NativePreviewPage {
    static let documentMarkup = """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="icon" type="image/png" sizes="64x64" href="favicon.png">
        <meta name="color-scheme" content="light dark"><title>iPhone-use · Live preview</title>
        <style>
        *{box-sizing:border-box} [hidden]{display:none!important}
        :root{color-scheme:light dark;--bg:#f5f5f7;--text:#1d1d1f;--muted:#68686d;--secondary:#515158\
        ;--solid:#fafafb;--button:#ffffff80;--hover:#fff;--pressed:#e8e9ed;--button-line:#2830440d\
        ;--focus:#0067db;--live:#168447;--waiting:#96601d;--error:#c33630;--shadow:#1e304329;font:14px\
         -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:var(--text);background:var(--bg)}
        @media(prefers-color-scheme:dark){:root{--bg:#161619;--text:#f5f5f7;--muted:#a1a1a9\
        ;--secondary:#c3c3ca;--solid:#29292e;--button:#ffffff09;--hover:#ffffff18;--pressed:#ffffff23\
        ;--button-line:#ffffff09;--focus:#91bdff;--live:#80d7a5;--waiting:#e4b670;--error:#ff9b95;--shadow:#0005}}
        body{margin:0}button{font:inherit;color:inherit;cursor:pointer\
        ;touch-action:manipulation}button:focus-visible,summary:focus-visible{outline:2px solid var(--focus)\
        ;outline-offset:4px}
        button:disabled{opacity:.4;cursor:default}
        /* Connection states occupy the screen aperture, beneath the physical bezel. */
        #notice{position:absolute;z-index:2;background:#10151e;pointer-events:none}
        #device[data-notice="true"] #placeholder{display:none}
        .viewer{position:relative;height:100dvh;display:flex;flex-direction:column;background:var(--bg)}
        .identity{position:absolute;left:50%;transform:translateX(-50%);z-index:4;display:flex\
        ;align-items:center;justify-content:center;gap:8px;max-width:calc(100% - 40px);min-height:32px\
        ;color:var(--secondary)}
        .device-label{display:flex;align-items:center;gap:8px;min-width:0;height:32px;padding:0 12px\
        ;border:1px solid var(--button-line);border-radius:999px;background:var(--solid);box-shadow:0 1px 3px\
         #00000008}
        .mark{width:18px;height:18px}#device-name{min-width:0;margin:0;font-size:13px;line-height:20px\
        ;font-weight:500;letter-spacing:-.1px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        #appearance-toggle{flex:none;width:32px;height:32px;padding:7px;display:grid;place-items:center\
        ;border:1px solid var(--button-line);border-radius:50%;background:var(--button)\
        ;transition:background-color 120ms ease,transform 120ms ease}
        #appearance-toggle:hover{background:var(--hover)}#appearance-toggle:active{background:var(--pressed)\
        ;transform:scale(.94)}
        svg{display:block}#appearance-toggle svg{width:16px;height:16px}
        .connection{display:grid;place-items:center;width:18px;height:24px;flex:none;color:var(--waiting)}
        .connection[data-kind="live"]{color:var(--live)}.connection[data-kind="error"]{color:var(--error)}
        @media(prefers-reduced-motion:reduce){#appearance-toggle{transition:none}#appearance-toggle:active{tr\
        ansform:none}}
        @media(prefers-contrast:more){.device-label\
        ,#appearance-toggle{border-color:var(--secondary)}.connection{outline:1px solid currentColor\
        ;outline-offset:2px;border-radius:5px}}
        .sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden\
        ;clip-path:inset(50%);white-space:nowrap;border:0}
        main{min-height:0;width:100%;flex:1;display:flex;flex-direction:column;align-items:center}
        #stage{position:relative;width:100%;flex:1;min-height:0;display:grid;place-items:center;overflow:hidden}
        #device{position:relative;flex:none}#screen{position:absolute;z-index:1;display:block\
        ;object-fit:contain;background:#08090b;visibility:hidden}
        #device[data-ready="true"] #screen{visibility:visible}
        #fold{position:absolute;left:50%;top:50%;z-index:6;pointer-events:none;transform-style:preserve-3d}
        .fold-panel{position:absolute;top:0;width:50%;height:100%;transform-style:preserve-3d}
        #fold-left{left:0;transform-origin:100% 50%}#fold-right{right:0;transform-origin:0 50%}
        .fold-face{position:absolute;inset:0;backface-visibility:hidden}
        #fold-inside-left{clip-path:inset(-32px 0 -32px -32px)}
        #fold-inside-right{clip-path:inset(-32px -32px -32px 0)}
        #fold-outer{transform:rotateY(180deg) translateZ(var(--fold-depth))}
        .fold-skin{position:absolute;transform-origin:0 0}
        .fold-glass{position:absolute;background:#10151e}
        .fold-face img{position:absolute;max-width:none;object-fit:contain;z-index:1}
        .fold-shade{position:absolute;inset:0;pointer-events:none;z-index:4;opacity:0\
        ;background:linear-gradient(90deg,#0000 70%,#03081266 100%)}
        #fold-shade-right{background:linear-gradient(90deg,#0009,#10203918 12%,#0000 35%)}
        #fold-edge{transform-style:preserve-3d}
        #fold-buttons{position:absolute;left:0;top:0;transform-origin:0 0}
        #fold-buttons .device-shell{left:0;top:0;transform:none!important}
        #fold-buttons .device-shell::before,#fold-buttons .device-shell::after\
        ,#fold-outer .side-key\
        ,.fold-skin .device-shell[data-duo="inner"] .side-key:not(.action-key):not(.camera-key){display:none}
        .fold-edge-layer{position:absolute;backface-visibility:visible;pointer-events:none}
        #gestures{position:absolute;z-index:5;pointer-events:none;overflow:hidden;isolation:isolate}
        #gestures svg{position:absolute;inset:0;width:100%;height:100%;overflow:hidden}
        .gesture-touch{fill:rgba(142,142,147,.48);stroke:rgba(255,255,255,.72);stroke-width:1\
        ;transform-box:fill-box;transform-origin:center;animation:touch-press var(--gesture-duration) ease-out\
         both}
        .gesture-motion{animation:touch-move var(--gesture-duration) cubic-bezier(.25,.1,.25,1) both}
        .gesture-double-tap .gesture-touch{animation-name:touch-double}
        .gesture-long-press .gesture-touch,.gesture-drag .gesture-touch{animation-name:touch-hold}
        .gesture-drag .gesture-motion{animation-name:touch-drag}
        @keyframes touch-press{0%{opacity:0;transform:scale(1.12)}12%{opacity:1;transform:scale(.92)}25%\
        ,70%{opacity:1;transform:scale(1)}100%{opacity:0;transform:scale(1.12)}}
        @keyframes touch-double{0%,42%{opacity:0;transform:scale(1.12)}12%,54%{opacity:1\
        ;transform:scale(.88)}25%,68%{opacity:1;transform:scale(1)}38%,100%{opacity:0;transform:scale(1.12)}}
        @keyframes touch-hold{0%{opacity:0;transform:scale(1.12)}10%,25%{opacity:1;transform:scale(.9)}35%\
        ,82%{opacity:1;transform:scale(1)}100%{opacity:0;transform:scale(1.12)}}
        @keyframes touch-move{0%,15%{transform:translate(0,0)}75%,100%{transform:translate(var(--dx),var(--dy))}}
        @keyframes touch-drag{0%,35%{transform:translate(0,0)}82%,100%{transform:translate(var(--dx),var(--dy))}}
        @media(prefers-reduced-motion:reduce){#gestures .gesture-touch{animation:none;opacity:1\
        ;transform:none}#gestures .gesture-motion{animation:none;transform:translate(var(--dx),var(--dy))}}
        #bezel{z-index:3;position:absolute;left:50%;top:50%;pointer-events:none;user-select:none}
        /* Static, independently authored materials. No blur, animation, canvas or per-frame drawing. */
        .device-shell,.device-hardware{position:absolute;left:50%;top:50%;pointer-events:none;user-select:none}
        .device-shell{border-radius:var(--outer-radius);background:linear-gradient(112deg,#8d9298 0%,#d1d5d8 4%\
        ,#5a6068 10%,#2b3036 35%,#949ba2 52%,#d9dde0 76%,#646b73 91%,#afb5bb 100%);box-shadow:0 0 0 1em\
         #0a0b0d,0 10em 28em var(--shadow),inset 0 0 0 1em #eff2f47a}
        .device-shell[data-finish="polished"]{background:linear-gradient(105deg,#e6e8e9,#656b72 8%,#e3e5e6 17%\
        ,#8c949b 38%,#f7f8f8 68%,#727980 86%,#d5dadd);box-shadow:0 0 0 1em #353a40,0 10em 28em var(--shadow)\
        ,inset 0 0 0 1em #fff9}
        .device-shell::before{content:"";position:absolute;inset:2.5em;border-radius:var(--inner-radius)\
        ;background:#08090b;box-shadow:0 0 0 .8em #171a1d,inset 0 0 0 1em #565b6270}
        .device-shell::after{content:"";position:absolute;inset:1em;border-radius:var(--edge-radius)\
        ;border:1em solid #ffffff24;pointer-events:none}
        .side-key{position:absolute;width:3em;border-radius:2em;background:linear-gradient(90deg,#33383e\
        ,#b2b8be 65%,#737b83);box-shadow:0 0 0 .5em #17191b}
        .action-key{left:-2.5em;top:19%;height:27em}.volume-up{left:-2.5em;top:27%\
        ;height:49em}.volume-down{left:-2.5em;top:35%;height:49em}.power-key{right:-2.5em;top:30%\
        ;height:73em}.camera-key{right:-1.5em;top:64%;height:49em;width:2em;background:#676d74}
        .antenna{position:absolute;width:3em;height:5em;background:#858990b0}.antenna.a{left:0\
        ;top:12%}.antenna.b{right:0;top:12%}.antenna.c{left:0;bottom:12%}.antenna.d{right:0;bottom:12%}
        .device-shell[data-generic="true"] .side-key,.device-shell[data-generic="true"] .antenna,.device-shell\
        [data-camera="false"]\
         .camera-key{display:none}
        .device-hardware{z-index:3}.device-cutout{position:absolute;background:#000;border-radius:var(--cutout-radius)}
        .device-cutout[data-shape="notch"]{border-radius:0 0 var(--cutout-radius) var(--cutout-radius)}
        .device-cutout[data-shape="notch"]::before{content:"";position:absolute;left:calc(0em - var(--shoulder))\
        ;top:0;width:calc(100% + 2 * var(--shoulder));height:var(--shoulder);background:radial-gradient(circle\
         var(--shoulder) at 0 100%,transparent calc(100% - .3em),#000 100%) left top,radial-gradient(circle\
         var(--shoulder) at 100% 100%,transparent calc(100% - .3em),#000 100%) right top\
        ;background-size:var(--shoulder) var(--shoulder);background-repeat:no-repeat}
        .device-cutout::after{content:"";position:absolute;left:var(--camera-x);top:var(--camera-y)\
        ;width:var(--camera-size);height:var(--camera-size);transform:translate(-50%,-50%);border-radius:50%\
        ;background:radial-gradient(circle at 37% 32%,#293d50 0%,#122130 23%,#080d15 48%,#151e2c 65%,#040609\
         75%);box-shadow:0 0 0 1em #090b10}
        .device-speaker{position:absolute;z-index:1;border-radius:8em;background:linear-gradient(#080a0d,#24272b 50%\
        ,#090b0e);box-shadow:inset 0 0 0 .6em #33373c}
        .device-shell[data-duo="outer"],.device-shell[data-duo="inner"]{background:linear-gradient(100deg,#152031\
        ,#7187a4 2%,#1a2637 4%,#111824 48%,#637b9c 96%,#1c293b);box-shadow:0 0 0 .6em #131b26\
        ,0 8em 20em var(--shadow),inset 0 0 0 .7em #a7b9d180}
        .device-shell[data-duo="inner"]{box-shadow:0 0 0 .6em #131b26,inset 0 0 0 .7em #a7b9d180}
        .body-shadow{display:none;position:absolute;inset:0;border-radius:inherit;pointer-events:none}
        .device-shell[data-duo="inner"] .body-shadow{display:block;box-shadow:0 8em 20em var(--shadow)}
        .device-shell[data-duo="outer"]{background:none;box-shadow:none;border-radius:0}
        .device-shell[data-duo="outer"]::before{inset:2.9em 0 0 10.3em;border-radius:5em 65.5em 65.5em 5em\
        ;background:#020407;box-shadow:0 0 0 .6em #02050b,0 8em 20em var(--shadow)\
        ,inset 0 0 0 .7em #b7cbe5\
        ,inset 0 0 0 1.5em #536d90,inset 0 0 0 2.3em #182638,inset 0 0 0 3.4em #060b12}
        .device-shell[data-duo="outer"]::after{inset:6.3em 3.4em 3.4em 13.7em\
        ;border-radius:7em 61em 61em 7em;border:.5em solid #40516a80\
        ;box-shadow:inset 1em 1em 1.5em #5b69804d,inset -1em -1em 1em #000}
        .device-shell[data-duo="inner"]::before{box-shadow:0 0 0 .7em #0a111b,inset 0 0 0 .8em #8497b2a0}
        .device-shell[data-duo="inner"] .side-key,.device-shell[data-duo="inner"] .antenna\
        ,.device-shell[data-duo="outer"] .action-key,.device-shell[data-duo="outer"] .camera-key{display:none}
        .device-shell[data-duo="inner"] .side-key:not(.action-key):not(.camera-key){display:block\
        ;background:linear-gradient(90deg,#121b2a,#b1c6e1 5%,#2d405b 12%,#1b293e 86%,#819bbb 96%,#101a29)\
        ;box-shadow:0 0 0 .4em #101926}
        .device-shell[data-duo="outer"] .side-key:not(.action-key):not(.camera-key){display:block\
        ;background:linear-gradient(90deg,#121b2a\
        ,#b1c6e1 5%,#2d405b 12%,#1b293e 86%,#819bbb 96%,#101a29);box-shadow:0 0 0 .4em #101926}
        .device-shell[data-duo="outer"] .volume-up,.device-shell[data-duo="outer"] .volume-down{top:0\
        ;width:58em;height:2.8em;border-radius:2em 2em .5em .5em}
        .device-shell[data-duo="outer"] .volume-up{left:200em}
        .device-shell[data-duo="outer"] .volume-down{left:270em}
        .device-shell[data-duo="outer"] .power-key{right:-2.3em;top:176em;width:3em;height:96.7em\
        ;border-radius:1.8em;background:linear-gradient(#17273b,#9fb9d9 3%,#2b3e58 7%,#1c2b40 45%\
        ,#2c3d55 92%,#9fb9d9 97%,#152337)}
        .device-shell[data-duo="outer"] .power-key::after{content:"";position:absolute;inset:5em .7em\
        ;background:#20314a;border-radius:1em;box-shadow:inset .4em 0 .5em #8da4c155}
        .device-shell[data-duo="outer"] .antenna{width:6em;height:5em;background:#657386a6}
        .device-shell[data-duo="outer"] .antenna.a{left:20%;top:2.9em}
        .device-shell[data-duo="outer"] .antenna.b{left:81%;right:auto;top:2.9em}
        .device-shell[data-duo="outer"] .antenna.c{left:35%;top:auto;bottom:0}
        .device-shell[data-duo="outer"] .antenna.d{left:65%;right:auto;top:auto;bottom:0}
        .duo-spine,.hinge-cap,.duo-seam{display:none;position:absolute}
        .device-hardware[data-duo="outer"] .duo-spine{display:block;left:0;top:9.5em;bottom:4em;width:10.3em\
        ;border-radius:8em 0 0 8em;background:linear-gradient(90deg,#111d2e,#91a8c7 13%,#435c7b 29%\
        ,#1e304a 52%,#162339 88%,#080e19);box-shadow:inset .5em 0 .8em #a7bbd8\
        ,inset 0 .8em 1.3em #8ca4c1,inset 0 -.7em 1em #778ca8}
        .device-hardware[data-duo="outer"] .duo-spine::before{content:"";position:absolute\
        ;inset:2.8em .7em 2.8em 3.2em;border-radius:4em 0 0 4em;background:#162338\
        ;box-shadow:inset .7em 0 1.2em #060c16,inset 0 .7em 1em #080f1c}
        .device-hardware[data-duo="outer"] .duo-spine::after{content:"";position:absolute\
        ;right:-.5em;top:0;bottom:0;width:1em;background:#03070e;box-shadow:.5em 0 0 #637a97}
        .device-hardware[data-duo="outer"] .duo-seam{display:block;right:0;width:3em;height:6em;background:#65738699}
        .duo-seam.first{top:13%}.duo-seam.second{bottom:12%}
        .device-hardware[data-duo="outer"] .device-cutout::after{background:\
        radial-gradient(ellipse 16% 34% at 39% 43%,#76633a88,transparent 90%),\
        radial-gradient(ellipse 16% 32% at 61% 57%,#202957b3,transparent 90%),\
        radial-gradient(circle,#05080e 0%,#080b16 24%,#1b1c2c 28%,#10111d 37%,#11121b 40%,#0d0e15 69%)\
        ;transform:translate(-50%,-50%) rotate(32deg);box-shadow:0 0 .4em .3em #080a10}
        .device-hardware[data-duo="inner"] .hinge-cap{display:block;top:50%;height:20em;width:7em\
        ;transform:translateY(-50%);border-radius:2em;border:.6em solid #18212e\
        ;background:linear-gradient(90deg,#263548,#8193a9 40%,#1b2634)}
        .hinge-cap.first{left:0}.hinge-cap.second{right:0}
        #placeholder{z-index:2;position:absolute;background:#10151e}
        #device[data-ready="true"] #placeholder{display:none}
        #diagnostics{padding:18px 28px;background:var(--bg);color:var(--secondary);font:12px ui-monospace\
        ,monospace}#metrics{white-space:pre-wrap;overflow-wrap:anywhere}summary{cursor:pointer}
        </style></head>
        <body><div class="viewer" id="viewer">
        <!-- Heroicons v2.2.0 (https://github.com/tailwindlabs/heroicons), embedded paths unchanged.
        MIT License

        Copyright (c) Tailwind Labs, Inc.

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        -->
        <main><div id="stage"><div id="device" data-ready="false"><div id="shell" class="device-shell" hidden \
        aria-hidden="true"><i class="body-shadow"></i><i\
         class="side-key action-key"></i><i class="side-key volume-up"></i><i class="side-key\
         volume-down"></i><i class="side-key power-key"></i><i class="side-key camera-key"></i><i\
         class="antenna a"></i><i class="antenna b"></i><i class="antenna c"></i><i class="antenna\
         d"></i></div><div id="hardware" class="device-hardware" hidden aria-hidden="true"><i id="speaker" cla\
        ss="device-speaker"></i><i id="cutout" class="device-cutout"\
         hidden></i><i class="duo-spine"></i><i class="hinge-cap first"></i><i class="hinge-cap second"></i>\
        <i class="duo-seam first"></i><i class="duo-seam second"></i>\
        </div><div id="gestures" aria-hidden="true"></div><img id="screen" alt="Live iPhone\
         screen" draggable="false"><div id="placeholder"><span id="placeholder-label" class="sr-only">Waiting\
         for iPhone screen</span></div><div id="notice" aria-hidden="true" hidden></div><img id="bezel" hidden\
         alt="" aria-hidden="true" draggable="false"></div><div id="fold" hidden aria-hidden="true"><div\
         class="fold-panel" id="fold-right"><div class="fold-face" id="fold-inside-right"><div class="fold-ski\
        n" id="fold-skin-right"></div><img\
         id="fold-image-right" alt=""><i class="fold-shade" id="fold-shade-right"></i></div><div id="fold-butt\
        ons"></div></div><div\
         class="fold-panel" id="fold-left"><div class="fold-face" id="fold-inside-left"><div class="fold-skin"\
         id="fold-skin-left"></div><img\
         id="fold-image-left" alt=""><i class="fold-shade" id="fold-shade-left"></i></div><div\
         class="fold-face" id="fold-outer"><div class="fold-skin" id="fold-skin-outer"></div><img\
         id="fold-image-outer" alt=""></div>\
        <div id="fold-edge"></div></div></div>\
        <footer class="identity" id="identity"><div\
         class="device-label"><div class="connection" id="connection" data-kind="waiting" role="status"\
         title="Connecting…"><svg aria-hidden="true" class="mark" xmlns="http://www.w3.org/2000/svg"\
         fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" data-slot="icon">  <path\
         stroke-linecap="round" stroke-linejoin="round" d="M10.5 1.5H8.25A2.25 2.25 0 0 0 6 3.75v16.5a2.25\
         2.25 0 0 0 2.25 2.25h7.5A2.25 2.25 0 0 0 18 20.25V3.75a2.25 2.25 0 0 0-2.25-2.25H13.5m-3 0V3h3V1.5m-3\
         0h3m-3 18.75h3"/></svg><span id="state" class="sr-only">Connecting…</span></div><h1\
         id="device-name">iPhone</h1></div><button id="appearance-toggle" hidden title="Use drawn frame"\
         aria-label="Use drawn frame"><svg aria-hidden="true" xmlns="http://www.w3.org/2000/svg" fill="none"\
         viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" data-slot="icon">  <path\
         stroke-linecap="round" stroke-linejoin="round" d="M16.5 8.25V6a2.25 2.25 0 0 0-2.25-2.25H6A2.25 2.25\
         0 0 0 3.75 6v8.25A2.25 2.25 0 0 0 6 16.5h2.25m8.25-8.25H18a2.25 2.25 0 0 1 2.25 2.25V18A2.25 2.25 0 0\
         1 18 20.25h-7.5A2.25 2.25 0 0 1 8.25 18v-1.5m8.25-8.25h-6a2.25 2.25 0 0 0-2.25\
         2.25v6"/></svg></button></footer></div>
        </main>
        </div><details id="diagnostics" hidden><summary id="diagnostics-label">Browser display metrics (last 1\
        ,800 frames)</summary><pre id="metrics"></pre></details>
        """
}
