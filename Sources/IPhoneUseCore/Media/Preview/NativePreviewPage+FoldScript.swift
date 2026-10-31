extension NativePreviewPage {
    static let foldScript = """
        let foldBaseline=null,foldOwner=null,foldAnimations=[],foldCount=0,lastFold=null;
        const foldTiming={duration:600,fill:'both',easing:'cubic-bezier(0.77,0,0.175,1)'};
        const fold=document.getElementById('fold'),foldLeft=document.getElementById('fold-left');
        const foldRight=document.getElementById('fold-right');
        const foldImages=['left','right','outer'].map(side=>document.getElementById('fold-image-'+side));
        function cancelFoldMotion(reason='cancelled'){
          if(foldAnimations.length&&lastFold)lastFold.state=reason;
          for(const animation of foldAnimations){animation.onfinish=null;animation.cancel();}
          foldAnimations=[];fold.hidden=true;
          for(const img of foldImages){img.removeAttribute('src');img.hidden=true;}
        }
        function foldPreview(from,to){
          lastFold={at:Date.now(),count:++foldCount,state:'started',mode:'hinge'};
          if(document.visibilityState!=='visible'){lastFold.state='skipped-hidden';return;}
          if(reducedMotion.matches){
            lastFold.mode='reduced-fade';
            foldAnimations=[device.animate([{opacity:0},{opacity:1}],{...foldTiming,duration:120})];
            foldAnimations[0].onfinish=()=>cancelFoldMotion('finished');return;
          }
          const start=canonicalFoldGeometry(from),end=canonicalFoldGeometry(to);
          const opening=to.duoKind==='inner',wide=opening?end:start,outer=opening?start:end;
          const turnDelta=((end.turn-start.turn)%360+540)%360-180;
          // Geometry may cross generations; image pixels never do. The visible
          // inner faces (opening) or outer back (closing) use this newly decoded
          // generation only. Cancellation removes every presentation copy immediately.
          const thickness=wide.height*.024;
          prepareFoldFaces(wide,outer,opening,thickness);
          fold.style.width=wide.width+'px';fold.style.height=wide.height+'px';
          const perspective=Math.max(1600,wide.width*6);
          fold.style.perspective=perspective+'px';
          fold.style.setProperty('--fold-depth',thickness+'px');
          fold.hidden=false;
          const poses=[],panels=[],backs=[],shades=[],captions=[],rearVisibility=[],keys=[],ambient=[];
          for(let step=0;step<=16;step++){
            const t=step/16,open=opening?t:1-t;
            const depth=wide.width/2*Math.sin(Math.PI*open);
            const projection=Math.max(0,Math.cos(Math.PI*(1-open)));
            const turn=start.turn+turnDelta*t,radians=turn*Math.PI/180;
            const cos=Math.cos(radians),sin=Math.sin(radians);
            let size=(start.height+(end.height-start.height)*t)/wide.height;
            if(step>0&&step<16){
              const width=wide.width*(1+projection)/2;
              size=Math.min(size,to.availableWidth/(width*Math.abs(cos)+wide.height*Math.abs(sin))\
        ,to.availableHeight/(width*Math.abs(sin)+wide.height*Math.abs(cos)));
            }
            const scale=size*(1-depth/perspective),shift=wide.width*scale*(1-projection)/4;
            const x=from.translateX+(to.translateX-from.translateX)*t-shift*cos;
            const y=from.translateY+(to.translateY-from.translateY)*t-shift*sin;
            poses.push({offset:t,transform:'translate(-50%,-50%) translate('+x+'px,'+y+'px) rotate('\
        +turn+'deg) scale('+scale+')'});
            panels.push({offset:t,transform:'translateZ('+(-thickness*(1-open))+'px) rotateY('\
        +(180*(1-open))+'deg)'});
            backs.push({offset:t,transform:'rotateY('+(8*Math.sin(Math.PI*open))+'deg)'});
            // A clipped full-screen shadow forms a hard rectangle behind a
            // nearly closed leaf. Reveal it only on the exposed inside surface.
            ambient.push({offset:t,opacity:Math.max(0,open*2-1)});
            shades.push({offset:t,opacity:Math.sin(Math.PI*open)});
            const sy=wide.height/outer.height,sx=sy+(wide.width/2/outer.width-sy)*open;
            keys.push({offset:t,transform:'translateX('+((wide.width/2-outer.width*sy)/2*(1-open))\
        +'px) translateY('+(-2.8*outer.width/436*sy*open)+'px) scale('+sx+','+sy+')'});
            rearVisibility.push({offset:t,opacity:open===0?0:1});
            captions.push({offset:t,transform:'translate(-50%,'+((from.captionTop-to.captionTop)*(1-t))+'px)'});
          }
          foldAnimations=[fold.animate(poses,foldTiming),foldLeft.animate(panels,foldTiming)\
        ,foldRight.animate(backs,foldTiming),identity.animate(captions,foldTiming)\
        ,...[...fold.querySelectorAll('.body-shadow')].map(el=>el.animate(ambient,foldTiming))\
        ,...['left','right'].map(side=>document.getElementById('fold-shade-'+side).animate(shades,foldTiming))\
        ,document.getElementById('fold-inside-right').animate(rearVisibility,foldTiming)\
        ,document.getElementById('fold-buttons').animate(keys,foldTiming)\
        ,document.getElementById('fold-edge').animate([{visibility:'hidden'}\
        ,{offset:.001,visibility:'visible'},{offset:.999,visibility:'visible'}\
        ,{visibility:'hidden'}],foldTiming)\
        ,device.animate([{opacity:0},{opacity:0}],foldTiming)\
        ,fold.animate([{opacity:1},{opacity:1}],foldTiming)];
          foldAnimations.at(-1).onfinish=()=>cancelFoldMotion('finished');
        }
        """
}
