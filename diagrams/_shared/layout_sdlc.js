/* sdlc layout page script: builds dialog models from PACK. */
(function(){
 var SK=PACK.skills,CATS=PACK.cats,ST=PACK.stages,ANY=PACK.any,SN=PACK.SN,L=PACK.L,PL={'claude-code':'Claude Code',cursor:'Cursor',codex:'Codex'};
 function label(id){if(id.indexOf('cat:')===0)return (CATS[id.slice(4)]||{}).name||id;if(id.indexOf('stage:')===0)return SN[id.slice(6)]||id.slice(6);if(id.indexOf('any:')===0)return (ANY[id.slice(4)]||{}).name||id;return SK[id]?SK[id].name:id}
 var names=Object.keys(SK).map(function(id){return [SK[id].name,id]}).concat(Object.keys(SK).filter(function(i){return SK[i].command}).map(function(id){return [SK[id].command,id]})).sort(function(a,b){return b[0].length-a[0].length});
 function chipify(t){var parts=String(t).split(/(\[\[[^\]]+\]\])/);return parts.map(function(p){if(p.indexOf('[[')===0)return p;
  names.forEach(function(n){var re=new RegExp('(^|[^\\w\\[/-])('+n[0].replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+')(?![\\w-])','g');p=p.replace(re,function(_,a){return a+'[['+n[1]+']]'})});return p}).join('')}
 function whenList(a){return (a||[]).map(chipify)}
 function sources(list){return {type:'node',label:'Sources',key:'use',v:function(body){var u=SM.el('ul');(list||[]).forEach(function(s){var li=SM.el('li'),a=SM.el('a',null,s.label);a.href=s.url;a.target='_blank';a.rel='noopener';a.style.color='var(--c)';li.appendChild(a);u.appendChild(li)});body.appendChild(u)}}}
 function srcBlock(list){if(!list||!list.length)return [];return [{label:'Sources',key:'use',type:'node',v:function(body){var u=SM.el('ul');list.forEach(function(s){var li=SM.el('li'),a=SM.el('a',null,s.label);a.href=s.url;a.target='_blank';a.rel='noopener';a.style.color='var(--c)';li.appendChild(a);u.appendChild(li)});body.appendChild(u)}}]}
 function skillModel(id){var s=SK[id],st=PACK.skillStage[id]||'anytime',B=[];
  var tags=[[s.command||s.name,1]];if(s.trigger)tags.push([s.trigger]);tags.push([st==='anytime'?L.anytime:SN[st]]);(s.platforms||[]).forEach(function(p){tags.push([PL[p]||p,0,p])});
  B.push({label:'When to use it',key:'when',type:'when',v:whenList(s.when)});B.push({label:'What it is',key:'is',type:'p',v:s.whatItIs});
  if(s.howItWorks)B.push({label:'How it works',key:'how',type:'ol',v:s.howItWorks});
  if(s.example){var e=s.example;B.push({label:'Example',key:'ex',type:'example',note:'Example',v:[['Situation',e.situation],['You type',e.youType,'code'],['What happens',e.whatHappens],['You get',e.youGet]]})}
  if(s.behindTheScenes)B.push({label:'Behind the scenes',key:'bts',type:'flows',v:s.behindTheScenes.map(function(f){return f.filter(function(x){return x!=='→'})})});
  if(s.calls&&s.calls.length)B.push({label:'Calls these',key:'calls',type:'flows',v:[[s.command||s.name].concat([s.calls.map(function(c){return '@'+c})])]});
  if(s.next&&s.next.length)B.push({label:'Next',key:'next',type:'chips',v:s.next});
  return {accent:'st-'+st+' calm',title:s.name,tags:tags,blocks:B.concat(srcBlock(s.sources))}}
 function stageModel(sid){var s=ST[sid]||{},cs=Object.keys(CATS).filter(function(c){return CATS[c].stage===sid}),B=[];
  B.push({label:'What this '+L.stage.toLowerCase()+' is for',key:'grp',type:'p',v:s.principle||'No '+L.items+' for this '+L.stage.toLowerCase()+' in this pack yet.'});
  B.push({type:'note',v:L.stageNote});
  if(s.when&&s.when.length)B.push({label:'When X → this '+L.stage.toLowerCase(),key:'when',type:'when',v:s.when});
  if(s.gap)B.push({label:'What this pack leaves out',key:'bts',type:'p',v:s.gap});
  if(cs.length)B.push({label:'Categories here',key:'how',type:'chips',v:cs.map(function(c){return 'cat:'+c})});
  return {accent:'st-'+sid+' calm',title:SN[sid]+' '+L.stage.toLowerCase(),tags:[[L.stage.toUpperCase()+' '+(PACK.order.indexOf(sid)+1),1],[cs.length+(cs.length===1?' category':' categories')]],blocks:B.concat(srcBlock(s.sources))}}
 function catModel(cid){var c=CATS[cid],B=[];
  B.push({label:'The principle',key:'grp',type:'p',v:c.principle||c.blurb});
  B.push({label:'When X → pick Y',key:'when',type:'when',v:whenList(c.when)});
  B.push(c.parallel?{label:'These run side by side',key:'how',type:'chips',v:c.chain}:{label:'The chain, in order',key:'how',type:'flows',v:[c.chain.map(function(x,i){return '@'+x})]});
  if(c.chainWhy)B.push({label:c.parallel?'Why side by side':'Why this order',key:'bts',type:'p',v:c.chainWhy});
  return {accent:'st-'+c.stage+' calm',title:c.name,tags:[['CATEGORY',1],[SN[c.stage]],[c.chain.length+' '+(c.chain.length===1?L.item:L.items)]],blocks:B.concat(srcBlock(c.sources))}}
 function anyModel(gid){var g=ANY[gid];return {accent:'st-anytime calm',title:g.name,tags:[[L.anytime.toUpperCase(),1],[g.items.length+' items']],blocks:[{label:'What it is for',key:'grp',type:'p',v:g.blurb||''},{type:'note',v:L.anyNote},{label:'In this group',key:'how',type:'chips',v:g.items}]}}
 function model(id){if(id.indexOf('stage:')===0)return stageModel(id.slice(6));if(id.indexOf('cat:')===0)return catModel(id.slice(4));if(id.indexOf('any:')===0)return anyModel(id.slice(4));return SK[id]?skillModel(id):null}
 SMPAGE={model:model,label:label,afterFilter:null};
 window.SMDATA={search:{},filt:{}};
 Object.keys(SK).forEach(function(k){var s=SK[k];SMDATA.search[k]=[s.name,s.command,s.trigger,s.whatItIs].join(' ');SMDATA.filt[k]=s.platforms||[]});
 Object.keys(CATS).forEach(function(c){SMDATA.search['cat:'+c]=CATS[c].name+' '+(CATS[c].blurb||'')});
})();
