extension NativePreviewPage {
    static let layoutScript = """
        function setDevice(s){
          if(connectedDevice.productType!==s.device?.productType){lastScreenSize=null;foldBaseline=null;}
          connectedDevice=s.device||{};profile=s.bezel||null;
          identityKey=JSON.stringify([connectedDevice,profile]);layout();
        }
        function fitPreview(width,height,ratioWidth,ratioHeight,captionHeight){
          const bottomInset=captionHeight+16;
          const scale=Math.max(0,Math.min((width-40)/ratioWidth,(height-40-bottomInset)/ratioHeight));
          return {scale,offsetY:-bottomInset/2,captionTop:(height-bottomInset+ratioHeight*scale)/2+16};
        }
        function layout(){
          const duo=duoFrame(connectedDevice.productType,screen.naturalWidth||lastScreenSize?.[0]\
        ,screen.naturalHeight||lastScreenSize?.[1]);
          const model=duo?.model||(Object.hasOwn(drawnModels\
        ,connectedDevice.productType)?drawnModels[connectedDevice.productType]:null);
          if(screen.naturalWidth&&screen.naturalHeight)lastScreenSize=[screen.naturalWidth,screen.naturalHeight];
          device.hidden=connectedDevice.productType==='iPhone19,4'&&!lastScreenSize;
          const w=lastScreenSize?.[0]||profile?.screenWidth||model?.[1]||390,\
         h=lastScreenSize?.[1]||profile?.screenHeight||model?.[2]||844, landscape=w>h;
          const ratio=Math.min(w,h)/Math.max(w,h);
          const tolerance=Math.max(.002,1/Math.max(w,h));
          const canShowOfficial=Boolean(artworkAvailable&&profile&&Math.abs(ratio-profile.screenWidth/profil\
        e.screenHeight)<tolerance&&rotation!=='rot180');
          const official=canShowOfficial&&!forceDrawing;
          const exact=model&&Math.abs(ratio-model[1]/model[2])<tolerance;
          const name=profile?.name||model?.[0]||connectedDevice.name||connectedDevice.productType||'iPhone';
          if(deviceName.textContent!==name){deviceName.textContent=name;deviceName.title=name;}
          const key=[w,h,rotation,artworkAvailable,forceDrawing,identityKey,stage.clientWidth\
        ,stage.clientHeight,identity.clientHeight,device.dataset.ready].join(':');
          if(key===layoutKey)return;layoutKey=key;
          const previous=capturePreviewGeometry();
          appearanceToggle.hidden=!appearanceComparisonEnabled||!canShowOfficial;
          labelButton(appearanceToggle,forceDrawing?text.official:text.drawn);
          const angle=landscape?(rotation==='rot90'?90:-90):(rotation==='rot180'?180:0);
          const rim=exact?model[3]:12, radius=exact?model[4]:32;
          const screenRatio=canShowOfficial?profile.screenWidth/profile.screenHeight:ratio;
          const drawing=duo?.frame||{canvasWidth:400+rim*2,canvasHeight:400/screenRatio+rim*2,screenX:rim,screenY:rim\
        ,screenWidth:400,screenHeight:400/screenRatio,cornerRadius:radius};
          const p=official?profile:drawing;
          // Fit both appearances against the same screen-centred envelope. PNG
          // transparent margins and independently drawn rims must not zoom the video.
          const candidates=canShowOfficial?[profile,drawing]:[p];
          const fitWidth=Math.max(...candidates.map(p=>(p.screenWidth+2*Math.max(p.screenX\
        ,p.canvasWidth-p.screenX-p.screenWidth))/p.screenWidth));
          const fitHeight=Math.max(...candidates.map(p=>(p.screenHeight+2*Math.max(p.screenY\
        ,p.canvasHeight-p.screenY-p.screenHeight))/p.screenWidth));
          const width=landscape?p.canvasHeight:p.canvasWidth,height=landscape?p.canvasWidth:p.canvasHeight;
          const sw=landscape?p.screenHeight:p.screenWidth,sh=landscape?p.screenWidth:p.screenHeight;
          const x=landscape?(angle===90?p.canvasHeight-p.screenY-p.screenHeight:p.screenY)\
        :(angle===180?p.canvasWidth-p.screenX-p.screenWidth:p.screenX);
          const y=landscape?(angle===90?p.screenX:p.canvasWidth-p.screenX-p.screenWidth)\
        :(angle===180?p.canvasHeight-p.screenY-p.screenHeight:p.screenY);
          const placement=fitPreview(stage.clientWidth,stage.clientHeight,landscape?fitHeight:fitWidth\
        ,landscape?fitWidth:fitHeight,identity.clientHeight);
          identity.style.top=placement.captionTop+'px';
          const screenScale=placement.scale;
          const scale=screenScale/p.screenWidth;
          device.style.width=width*scale+'px';device.style.height=height*scale+'px';
          const translateX=((width-sw)/2-x)*scale;
          const translateY=((height-sh)/2-y)*scale+placement.offsetY;
          device.style.transform='translate('+translateX+'px,'+translateY+'px)';
          device.style.transformOrigin=(x+sw/2)*scale+'px '+(y+sh/2)*scale+'px';
          device.dataset.appearance=official?'official':exact?'drawn':'generic';
          screen.style.left=x*scale+'px';screen.style.top=y*scale+'px';
          screen.style.width=sw*scale+'px';screen.style.height=sh*scale+'px';
          screen.style.borderRadius=duo?orientedCorners(duo.radii,angle).map(r=>r*scale+'px').join(' ')
        :p.cornerRadius*scale+'px';
          for(const id of ['gestures','notice','placeholder'])for(const property of ['left','top','width'\
        ,'height','borderRadius'])document.getElementById(id).style[property]=screen.style[property];
          document.getElementById('gestures').innerHTML='';
          bezel.hidden=!official;shell.hidden=official;hardware.hidden=official;
          shell.dataset.duo=hardware.dataset.duo=duo?.kind||'';
          const transform='translate(-50%,-50%) rotate('+angle+'deg)';
          if(official){
            if(!bezel.dataset.loaded){bezel.dataset.loaded='true';bezel.src='bezel';}
            bezel.style.width=p.canvasWidth*scale+'px';bezel.style.height=p.canvasHeight*scale+'px'\
        ;bezel.style.transform=transform;
          }else{
            for(const layer of [shell,hardware]){
              layer.style.width=p.canvasWidth*scale+'px';layer.style.height=p.canvasHeight*scale+'px';
              layer.style.fontSize=scale+'px';layer.style.transform=transform;
            }
            for(const [key,inset] of [['outer',0],['inner',2.5],['edge',1]]){
              const corners=duo?.radii||[radius];
              shell.style.setProperty('--'+key+'-radius',corners.map(r=>(r+rim-inset)+'em').join(' '));
            }
            shell.dataset.finish=exact?model[7]:'satin';shell.dataset.generic=String(!exact)\
        ;shell.dataset.camera=String(Boolean(exact&&model[8]));
            cutout.hidden=!exact||duo?.kind==='inner';speaker.hidden=!exact||Boolean(duo);
            if(exact){
              const sensor=model[6], [cx,cy,cw,ch,cr,shoulder]=sensor.cutout;
              cutout.dataset.shape=model[5];
              cutout.style.left=(p.screenX+cx)+'em';cutout.style.top=(p.screenY+cy)+'em';
              cutout.style.width=cw+'em';cutout.style.height=ch+'em';
              cutout.style.setProperty('--cutout-radius',cr+'em');cutout.style.setProperty('--shoulder'\
        ,shoulder+'em');
              cutout.style.setProperty('--camera-x',(sensor.camera[0]-cx)+'em');
              cutout.style.setProperty('--camera-y',(sensor.camera[1]-cy)+'em');
              cutout.style.setProperty('--camera-size',sensor.camera[2]+'em');
              const [sx,sy,sw,sh]=sensor.speaker;
              speaker.style.left=(p.screenX+sx)+'em';speaker.style.top=(p.screenY+sy)+'em';
              speaker.style.width=sw+'em';speaker.style.height=sh+'em';
            }
          }
          layoutDuoKeys(duo?.kind,drawing);
          movePreview(previous,{angle,width:width*scale,height:height*scale,ratio,product:connectedDevice.productType\
        ,duoKind:duo?.kind,bezel:duo?snapshotFoldBezel():null,aperture:{x:x*scale,y:y*scale,width:sw*scale,hei\
        ght:sh*scale\
        ,radius:screen.style.borderRadius},scale:screenScale,translateX,translateY,offsetY:placement.offsetY\
        ,captionTop:placement.captionTop,live:device.dataset.ready==='true',surface:identityKey+':'+official\
        +':'+exact+':'+screenRatio.toFixed(3),fitWidth,fitHeight,availableWidth:Math.max(0,stage.clientWidth-40)\
        ,availableHeight:Math.max(0,stage.clientHeight-40-identity.clientHeight-16)});
        }
        appearanceToggle.addEventListener('click'\
        ,()=>{if(appearanceComparisonEnabled){forceDrawing=!forceDrawing;layout();}});
        bezel.addEventListener('error',()=>{artworkAvailable=false;layout();});
        const layoutObserver=new ResizeObserver(layout);
        for(const el of [stage,identity])layoutObserver.observe(el);layout();
        """
}
