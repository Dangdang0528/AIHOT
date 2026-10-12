// 沙箱出口中继：框架的 PinnedProxyClient 出于防 DNS rebinding 会发 `CONNECT <解析出的IP>:443`，
// 而本沙箱的出口代理(127.0.0.1:18080)只接受 `CONNECT <域名>:443`。本中继在本地监听，
// 收到 CONNECT 后：若是 IP 权威，则从 TLS ClientHello 里解析 SNI 还原域名；随后以域名权威
// 向沙箱代理发起 CONNECT 并双向透传。把 EGRESS_PROXY_URL 指向本中继即可。
import net from "node:net";
import http from "node:http";

const LISTEN_PORT = Number(process.env.SANDBOX_RELAY_PORT || 18090);
const UP_HOST = "127.0.0.1";
const UP_PORT = 18080;

/** 从 TLS ClientHello 记录中解析 SNI 主机名；解析失败返回 null。 */
function parseSni(buf) {
  try {
    let p = 0;
    if (buf[0] !== 0x16) return null;                 // handshake
    p = 5;                                            // record header
    if (buf[p] !== 0x01) return null;                 // client_hello
    p += 4 + 2 + 32;                                  // handshake hdr + version + random
    const sidLen = buf[p]; p += 1 + sidLen;           // session id
    const csLen = buf.readUInt16BE(p); p += 2 + csLen;// cipher suites
    const compLen = buf[p]; p += 1 + compLen;         // compression
    if (p + 2 > buf.length) return null;
    const extTotal = buf.readUInt16BE(p); p += 2;
    const extEnd = p + extTotal;
    while (p + 4 <= extEnd) {
      const type = buf.readUInt16BE(p);
      const len = buf.readUInt16BE(p + 2);
      p += 4;
      if (type === 0x0000) {                          // server_name
        let q = p + 2;                                // list length
        q += 1;                                       // name type (host_name)
        const nameLen = buf.readUInt16BE(q); q += 2;
        return buf.toString("utf8", q, q + nameLen);
      }
      p += len;
    }
  } catch { /* fall through */ }
  return null;
}

function upstreamConnect(hostname, port, onReady, onError) {
  const up = net.connect(UP_PORT, UP_HOST, () => {
    console.log(`[relay] -> upstream CONNECT ${hostname}:${port}`);
    up.write(`CONNECT ${hostname}:${port} HTTP/1.1\r\nHost: ${hostname}:${port}\r\n\r\n`);
  });
  up.on("error", (e) => { console.log(`[relay] upstream socket error: ${e.message}`); onError(e); });
  const chunks = [];
  let parsed = false;
  const onData = (chunk) => {
    if (parsed) return;
    chunks.push(chunk);
    const reply = Buffer.concat(chunks).toString("latin1");
    const idx = reply.indexOf("\r\n\r\n");
    if (idx === -1) return;
    parsed = true;
    up.removeListener("data", onData);
    const statusLine = reply.slice(0, reply.indexOf("\r\n"));
    if (/^HTTP\/1\.[01] 2\d\d/.test(statusLine)) {
      const all = Buffer.concat(chunks);
      const leftover = all.subarray(Buffer.byteLength(reply.slice(0, idx + 4), "latin1"));
      onReady(up, leftover);
    } else {
      up.destroy();
      onError(new Error(`upstream refused: ${statusLine}`));
    }
  };
  up.on("data", onData);
}

const server = http.createServer((req, clientSock) => {
  // 普通（明文 HTTP）代理请求：直接把绝对 URL 请求行透传给上游代理。
  const upstream = net.connect(UP_PORT, UP_HOST, () => {
    upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n`);
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      upstream.write(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`);
    }
    upstream.write("\r\n");
    req.pipe(upstream);
  });
  upstream.pipe(clientSock);
  upstream.on("error", () => clientSock.destroy());
  clientSock.on("error", () => upstream.destroy());
});

server.on("connect", (req, clientSock, head) => {
  const authority = req.url;                          // host:port 或 ip:port
  console.log(`[relay] CONNECT ${authority}`);
  const hostPart = authority.split(":")[0];
  const port = Number(authority.split(":")[1] || 443);
  const buffered = [];
  if (head && head.length) buffered.push(head);

  const finish = (targetHost) => {
    upstreamConnect(targetHost, port, (up, leftover) => {
      clientSock.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      for (const b of buffered) up.write(b);
      if (leftover && leftover.length) up.write(leftover);
      clientSock.pipe(up);
      up.pipe(clientSock);
      clientSock.on("error", () => up.destroy());
      up.on("error", () => clientSock.destroy());
    }, (err) => {
      try { clientSock.write("HTTP/1.1 502 Bad Gateway\r\n\r\n"); } catch { /* ignore */ }
      clientSock.destroy(err);
    });
  };

  if (net.isIP(hostPart) === 0) {
    finish(hostPart);                                  // 本来就是域名权威
    return;
  }
  // IP 权威：等待 ClientHello，解析 SNI
  const timer = setTimeout(() => {
    cleanup();
    try { clientSock.write("HTTP/1.1 502 Bad Gateway\r\n\r\n"); } catch { /* ignore */ }
    clientSock.destroy();
  }, 8000);
  const cleanup = () => { clearTimeout(timer); clientSock.removeListener("readable", onReadable); clientSock.resume(); };
  function onReadable() {
    let chunk;
    while ((chunk = clientSock.read())) buffered.push(chunk);
    const sni = parseSni(Buffer.concat(buffered));
    if (sni) { cleanup(); finish(sni); }
  }
  clientSock.on("readable", onReadable);
});

server.listen(LISTEN_PORT, "127.0.0.1", () => {
  console.log(JSON.stringify({ msg: "sandbox egress relay listening", listen: `127.0.0.1:${LISTEN_PORT}`, upstream: `${UP_HOST}:${UP_PORT}` }));
});
