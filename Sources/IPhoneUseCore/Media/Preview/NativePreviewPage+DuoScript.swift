extension NativePreviewPage {
    static let duoScript = """
        // Independently drawn geometry, not embedded Apple artwork. The active
        // surface comes from a validated frame, never a guessed fold sensor.
        function duoFrame(product,width,height){
          if(product!=='iPhone19,4'||!width||!height)return null;
          const ratio=Math.min(width,height)/Math.max(width,height);
          const tolerance=Math.max(.002,1/Math.max(width,height));
          const outer=Math.abs(ratio-1398/2034)<tolerance,inner=Math.abs(ratio-2007/2853)<tolerance;
          if(!outer&&!inner)return null;
          const rim=outer?14:12.35,radius=outer?51.5:32.7;
          const sensor={cutout:outer?[343.35,25.46,31.47,31.19,15.7,0]:[0,0,0,0,0,0]\
        ,camera:[359.08,41.06,17.2],speaker:[0,0,0,0]};
          const model=['iPhone Duo',outer?1398:2007,outer?2034:2853,rim,radius,'camera',sensor,'satin',false];
          const heightUnits=400*model[2]/model[1],x=outer?22:rim,y=outer?16:rim;
          return {kind:outer?'outer':'inner',model,radii:outer?[8.6,radius,radius,8.6]:Array(4).fill(radius)\
        ,frame:{canvasWidth:x+400+rim,canvasHeight:y+heightUnits+rim,screenX:x,screenY:y\
        ,screenWidth:400,screenHeight:heightUnits,cornerRadius:radius}};
        }
        function layoutDuoKeys(kind,frame){
          // Buttons belong to the fixed half. Position them in the portrait
          // coordinate space; the shell's existing rotation carries them with it.
          for(const key of shell.querySelectorAll('.side-key')){
            key.style.cssText='';
            if(kind!=='inner')continue;
            const half=frame.canvasHeight/2,outer=duoFrame('iPhone19,4',1398,2034).frame;
            const x=half/outer.canvasWidth,y=frame.canvasWidth/outer.canvasHeight;
            if(key.classList.contains('power-key')){
              Object.assign(key.style,{left:173.2*y+'em',top:-2.3*x+'em',right:'auto'        ,width:96.7*y+'em\
        ',height:3*x+'em'});
            }else if(key.classList.contains('volume-up')||key.classList.contains('volume-down')){
              const start=key.classList.contains('volume-up')?200:270;
              Object.assign(key.style,{left:-2.8*y+'em',top:(half-(start+58)*x)+'em'        ,width:2.8*y+'em',\
        height:58*x+'em'});
            }
          }
        }
        function orientedCorners(radii,angle){
          const shift=((Math.round(angle/90)%4)+4)%4;
          return radii.map((_,index)=>radii[(index-shift+4)%4]);
        }
        """
}
