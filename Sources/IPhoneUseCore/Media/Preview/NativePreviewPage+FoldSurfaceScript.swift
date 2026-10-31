extension NativePreviewPage {
    static let foldSurfaceScript = """
        function snapshotFoldBezel(){
          // Only inert bezel nodes cross generations. Never clone screen/notice
          // or retain an image URL in the geometry baseline.
          return [shell,hardware].map(node=>{
            const copy=node.cloneNode(true);
            for(const el of [copy,...copy.querySelectorAll('[id]')])el.removeAttribute('id');
            return copy;
          });
        }
        function canonicalFoldGeometry(g){
          // The hinge is vertical in this local space: inner landscape, outer
          // portrait. Rotate the assembled device, not the hinge axis or pixels.
          const base=g.duoKind==='inner'?90:0,turn=g.angle-base;
          const quarter=((Math.round(turn/90)%4)+4)%4;
          const cos=[1,0,-1,0][quarter],sin=[0,1,0,-1][quarter];
          const sideways=quarter%2,width=sideways?g.height:g.width,height=sideways?g.width:g.height;
          const a=g.aperture,cx=a.x+a.width/2-g.width/2,cy=a.y+a.height/2-g.height/2;
          const aw=sideways?a.height:a.width,ah=sideways?a.width:a.height;
          const aperture={x:width/2+cos*cx+sin*cy-aw/2,y:height/2-sin*cx+cos*cy-ah/2\
        ,width:aw,height:ah,radius:orientedCorners(a.radius.split(' ').map(parseFloat),-turn)\
        .map(r=>r+'px').join(' ')};
          const bezel=g.bezel.map(node=>{
            const copy=node.cloneNode(true);
            copy.style.transform='translate(-50%,-50%) rotate('+base+'deg)';return copy;
          });
          return {...g,width,height,turn,aperture,bezel,image:g.aperture};
        }
        function prepareFoldFaces(wide,outer,opening,depth){
          const half=wide.width/2,factor=wide.height/outer.height;
          const dx=(half-outer.width*factor)/2;
          const fresh=screen.currentSrc||screen.src;
          function place(side,geometry,x,factor,show){
            const skin=document.getElementById('fold-skin-'+side),a=geometry.aperture;
            const img=document.getElementById('fold-image-'+side);
            skin.replaceChildren(...geometry.bezel.map(node=>node.cloneNode(true)));
            skin.style.width=geometry.width+'px';skin.style.height=geometry.height+'px';
            skin.style.left=x+'px';skin.style.top='0';skin.style.transform='scale('+factor+')';
            const glass=document.createElement('div');glass.className='fold-glass';
            Object.assign(glass.style,{left:a.x+'px',top:a.y+'px',width:a.width+'px',height:a.height+'px'\
        ,borderRadius:a.radius});skin.append(glass);
            const source=geometry.image;
            Object.assign(img.style,{left:(a.x+a.width/2-source.width/2)+'px'\
        ,top:(a.y+a.height/2-source.height/2)+'px',width:source.width+'px',height:source.height+'px'\
        ,borderRadius:source.radius,transform:'rotate('+(-geometry.turn)+'deg)'});skin.append(img);
            img.hidden=!show||!fresh;
            if(show&&fresh)img.src=fresh;else img.removeAttribute('src');
          }
          place('left',wide,0,1,opening);place('right',wide,-half,1,opening);
          place('outer',outer,dx,factor,!opening);
          const buttons=outer.bezel[0].cloneNode(true);
          buttons.replaceChildren(...buttons.querySelectorAll('.side-key'));
          document.getElementById('fold-buttons').replaceChildren(buttons);
          buildFoldEdge(wide,outer,depth,dx,factor);
        }
        function buildFoldEdge(wide,outer,depth,dx,factor){
          const edge=document.getElementById('fold-edge');edge.replaceChildren();
          const half=wide.width/2,unit=outer.width/436*factor;
          const frontRadius=parseFloat(wide.aperture.radius)+wide.aperture.x;
          // The inner screen reaches the hinge, but the chassis ends inside
          // the closed front rim. Taper only the free rounded edge: extending
          // slices to the inner hinge/top exposes a rectangular tab near closure.
          const right=half-Math.max(0,dx+10.3*unit),top=2.9*unit;
          // Bounded sub-pixel slices form a rounded solid edge, including the
          // corners. No detached vertical wire, outline or border at the hinge.
          const slices=Math.max(2,Math.ceil(depth*2));
          for(let index=1;index<slices;index++){
            const t=index/slices,layer=document.createElement('i');layer.className='fold-edge-layer';
            const x=(half-dx-outer.width*factor)*t;
            const radius=frontRadius+(65.5*unit-frontRadius)*t;
            Object.assign(layer.style,{left:x+'px',top:top+'px',width:(right-x)+'px'\
        ,height:(wide.height-top)+'px',borderRadius:[radius,5*unit,5*unit,radius]\
        .map(r=>r+'px').join(' '),transform:'translateZ('+(-depth*t)+'px)'\
        ,background:'linear-gradient(90deg,#536174,#778496 8%,#374354 50%,#1c2634)'});
            edge.append(layer);
          }
        }
        function updateFoldFrame(url){
          if(fold.hidden)return;
          // displayFrame already decoded this generation's resource. Keep both
          // inside halves on the same live frame, including the final handoff.
          for(const img of foldImages)if(!img.hidden)img.src=url;
        }
        """
}
