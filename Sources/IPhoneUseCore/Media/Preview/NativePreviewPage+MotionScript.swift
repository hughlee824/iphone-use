extension NativePreviewPage {
    static let motionScript = """
        const reducedMotion=matchMedia('(prefers-reduced-motion: reduce)');
        const rotationTiming={duration:250,easing:'cubic-bezier(0.77,0,0.175,1)'};
        let previousGeometry=null,deviceMotion=null,captionMotion=null;
        function cancelPreviewMotion(){
          deviceMotion?.cancel();captionMotion?.cancel();
          deviceMotion=null;captionMotion=null;
        }
        function resetPreviewMotion(){cancelPreviewMotion();previousGeometry=null;}
        // Cancellation reveals the settled layout. Keep that baseline for the
        // first fresh rotation after resuming; only a stream reset discards it.
        reducedMotion.addEventListener('change',()=>{if(reducedMotion.matches)cancelPreviewMotion();});
        document.addEventListener('visibilitychange',()=>{
          if(document.visibilityState!=='visible')cancelPreviewMotion();
        });
        function capturePreviewGeometry(){
          if(!previousGeometry)return null;
          const previous={...previousGeometry,active:deviceMotion?.playState==='running'};
          if(previous.active){
            // Read only when layout changes, never on ordinary video frames.
            // Retarget from the visible angle/scale if another rotation interrupts.
            const matrix=new DOMMatrixReadOnly(getComputedStyle(device).transform);
            previous.angle+=Math.atan2(matrix.b,matrix.a)*180/Math.PI;
            previous.scale*=Math.hypot(matrix.a,matrix.b);
            previous.offsetY+=matrix.f-previous.translateY;
            const caption=new DOMMatrixReadOnly(getComputedStyle(identity).transform);
            previous.captionTop+=caption.f;
          }
          return previous;
        }
        function movePreview(previous,next){
          cancelPreviewMotion();
          previousGeometry=next;
          if(!previous||!previous.live||!next.live||previous.surface!==next.surface\
        ||reducedMotion.matches||document.visibilityState!=='visible'\
        ||(!previous.active&&previous.angle===next.angle))return;
          const delta=((previous.angle-next.angle)%360+540)%360-180;
          const scale=previous.scale/next.scale;
          if(!Number.isFinite(scale)||scale<=0)return;
          // Sample the diagonal envelope so a tall phone stays inside a narrow
          // viewer during the turn. Only transforms animate, on the common parent;
          // JPEG decoding and replacement continue independently.
          const frames=[],captions=[];
          for(let step=0;step<=16;step++){
            const t=step/16,turn=delta*(1-t),radians=(next.angle+turn)*Math.PI/180;
            const cos=Math.abs(Math.cos(radians)),sin=Math.abs(Math.sin(radians));
            const width=next.fitWidth*cos+next.fitHeight*sin;
            const height=next.fitWidth*sin+next.fitHeight*cos;
            const size=step===0?previous.scale:step===16?next.scale\
        :Math.min(previous.scale+(next.scale-previous.scale)*t\
        ,next.availableWidth/width,next.availableHeight/height);
            const offsetY=previous.offsetY+(next.offsetY-previous.offsetY)*t;
            frames.push({offset:t,transform:'translate('+next.translateX+'px,'\
        +(next.translateY+offsetY-next.offsetY)+'px) rotate('+turn+'deg) scale('+(size/next.scale)+')'});
            const captionTop=step===0?previous.captionTop:step===16?next.captionTop\
        :stage.clientHeight/2+offsetY+height*size/2+16;
            captions.push({offset:t,transform:'translate(-50%,'+(captionTop-next.captionTop)+'px)'});
          }
          deviceMotion=device.animate(frames,rotationTiming);
          captionMotion=identity.animate(captions,rotationTiming);
        }
        """
}
