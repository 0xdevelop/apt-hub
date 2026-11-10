// 测试专用：元数据 HTTPS + github.com CONNECT→回环资产。不进生产。
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';

const [siteArg, assetsArg, certFile, keyFile, readyFile, accessFile] = process.argv.slice(2);
if (!accessFile) throw new Error('需要站点、资产、证书、私钥、就绪文件和访问日志');
const siteRoot = fs.realpathSync(siteArg);
const assetsRoot = fs.realpathSync(assetsArg);
const tlsOptions = { cert: fs.readFileSync(certFile), key: fs.readFileSync(keyFile) };
const sockets = new Set();
function log(role, request, status) {
  fs.appendFileSync(accessFile, JSON.stringify({role,method:request.method,url:request.url,status})+'\n');
}
function serve(root, role) {
  return (request, response) => {
    let name;
    try { name = decodeURIComponent(new URL(request.url, 'https://fixture.invalid').pathname); }
    catch { response.writeHead(400).end(); return; }
    if (name.includes('..') || name.includes('\\') || !['GET','HEAD'].includes(request.method)) {
      log(role,request,400); response.writeHead(400).end(); return;
    }
    const file = path.resolve(root,'.'+name);
    if (!file.startsWith(root+path.sep) || (role==='metadata' && file.endsWith('.deb'))) {
      log(role,request,403); response.writeHead(403).end(); return;
    }
    let stat;
    try { stat=fs.lstatSync(file); } catch { log(role,request,404); response.writeHead(404).end(); return; }
    if (!stat.isFile() || stat.isSymbolicLink()) { log(role,request,404); response.writeHead(404).end(); return; }
    log(role,request,200);
    response.writeHead(200,{'Content-Type':'application/octet-stream','Content-Length':String(stat.size),'Connection':'close'});
    if(request.method==='HEAD') response.end();
    else fs.createReadStream(file).pipe(response);
  };
}
function track(server) {
  server.on('connection',socket=>{sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});
  server.on('error',error=>{console.error(error);process.exitCode=1;stop();});
}
const metadata=https.createServer(tlsOptions,serve(siteRoot,'metadata'));
const assetServer=https.createServer(tlsOptions,serve(assetsRoot,'release-fixture'));
const proxy=http.createServer((_request,response)=>response.writeHead(405).end());
for(const server of [metadata,assetServer,proxy]) track(server);
proxy.on('connect',(request,client,head)=>{
  if(request.url!=='github.com:443'){client.end('HTTP/1.1 403 Forbidden\r\n\r\n');return;}
  const upstream=net.connect(assetServer.address().port,'127.0.0.2',()=>{
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if(head.length) upstream.write(head);
    client.pipe(upstream).pipe(client);
  });
  upstream.on('error',()=>client.destroy());
  client.on('error',()=>upstream.destroy());
  client.on('close',()=>upstream.destroy());
});
await Promise.all([metadata,assetServer,proxy].map(server=>new Promise(resolve=>server.listen(0,'127.0.0.2',resolve))));
fs.writeFileSync(readyFile,JSON.stringify({site_url:`https://127.0.0.2:${metadata.address().port}`,proxy_url:`http://127.0.0.2:${proxy.address().port}`,pid:process.pid}));
console.log('apt_release_fixture_ready');
function stop(){for(const socket of sockets) socket.destroy();for(const server of [metadata,assetServer,proxy]) server.close();}
for(const signal of ['SIGINT','SIGTERM']) process.on(signal,()=>{stop();process.exit(0);});
