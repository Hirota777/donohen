const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export async function serveShare(req,res,fetcher=fetch,env=process.env){
 res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');res.setHeader('X-Robots-Tag','noindex, nofollow');res.setHeader('Cache-Control','no-store');
 if(req.method!=='GET'&&req.method!=='HEAD'){res.statusCode=405;res.setHeader('Allow','GET, HEAD');res.end('Method not allowed');return}
 const token=typeof req.query?.token==='string'?req.query.token:'';
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token)){res.statusCode=404;res.end('Not found');return}
 const url=env.VITE_SUPABASE_URL,key=env.VITE_SUPABASE_PUBLISHABLE_KEY||env.VITE_SUPABASE_ANON_KEY;
 if(!url||!key){res.statusCode=503;res.end('Temporarily unavailable');return}
 const image=req.query?.image==='1';let card;
 try{const response=await fetcher(`${url.replace(/\/$/,'')}/rest/v1/rpc/spectrum_get_result_share`,{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify({p_token:token,p_image:image}),signal:AbortSignal.timeout(8000)});if(!response.ok)throw Error('Backend unavailable');card=await response.json()}catch{res.statusCode=503;res.end('Temporarily unavailable');return}
 if(!card||!card.name||Date.parse(card.expiresAt)<=Date.now()){res.statusCode=404;res.end('This result is unavailable or expired.');return}
 const ttl=Math.max(0,Math.min(300,Math.floor((Date.parse(card.expiresAt)-Date.now())/1000)));
 res.setHeader('Cache-Control',`public, max-age=${ttl}, s-maxage=${ttl}`);
 if(image){if(typeof card.image!=='string'||card.image.length>620000){res.statusCode=404;res.end('Not found');return}const buffer=Buffer.from(card.image,'base64');res.setHeader('Content-Type','image/png');res.setHeader('Content-Length',String(buffer.length));res.end(req.method==='HEAD'?undefined:buffer);return}
 const configured=env.PUBLIC_SITE_URL||(env.VERCEL_PROJECT_PRODUCTION_URL?`https://${env.VERCEL_PROJECT_PRODUCTION_URL}`:'https://donohen-sigma.vercel.app/');
 let site;try{site=new URL(configured);if(site.protocol!=='https:')throw Error('Invalid site')}catch{res.statusCode=503;res.end('Temporarily unavailable');return}
 const page=new URL('/api/share',site);page.searchParams.set('token',token);const imageUrl=new URL(page);imageUrl.searchParams.set('image','1');
 const title=`${card.name}のドノヘン？ — ${card.rank}位・${card.score}点`;
 const description=card.bestHint?`ベストヒント「${card.bestHint.clue}」 平均${card.bestHint.average}点。ことばでつたえる、みんなのものさし。`:'ことばでつたえる、みんなのものさし。';
 const html=`<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)}</title><meta name="description" content="${escapeHtml(description)}"><meta property="og:type" content="website"><meta property="og:title" content="${escapeHtml(title)}"><meta property="og:description" content="${escapeHtml(description)}"><meta property="og:url" content="${escapeHtml(page.href)}"><meta property="og:image" content="${escapeHtml(imageUrl.href)}"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="og:image:type" content="image/png"><meta property="og:image:alt" content="${escapeHtml(title)}"><meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${escapeHtml(title)}"><meta name="twitter:description" content="${escapeHtml(description)}"><meta name="twitter:image" content="${escapeHtml(imageUrl.href)}"><style>body{margin:0;padding:32px 18px;background:linear-gradient(135deg,#eaf6ff,#fff1f6,#fff5d9);font-family:system-ui,sans-serif;color:#263655;text-align:center}main{max-width:540px;margin:auto}img{max-width:100%;height:auto;border-radius:22px}a{display:block;padding:16px;margin:20px 0;border-radius:12px;background:#ec638e;color:#fff;text-decoration:none;font-weight:bold}p{font-size:13px}</style></head><body><main><h1>${escapeHtml(title)}</h1><img src="${escapeHtml(imageUrl.href)}" alt="${escapeHtml(title)}"><a href="${escapeHtml(site.href)}">ドノヘン？で遊ぶ</a><p>共有された結果です。公開から7日間表示します。</p></main></body></html>`;
 res.setHeader('Content-Type','text/html; charset=utf-8');res.setHeader('Content-Security-Policy',`default-src 'none'; img-src 'self' ${site.origin}; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`);res.end(req.method==='HEAD'?undefined:html);
}

