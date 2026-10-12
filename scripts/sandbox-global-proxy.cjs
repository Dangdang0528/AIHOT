// 通过 NODE_OPTIONS --require 注入：把 Node 全局 HTTP dispatcher 固定为
// EnvHttpProxyAgent（读取 HTTP(S)_PROXY/NO_PROXY），使框架采集请求（关闭自带 dispatcher 后）
// 与普通 fetch 都走沙箱平台代理 127.0.0.1:18080 出网。仅用于沙箱本地测试。
try {
  const undici = require("/workspace/node_modules/undici");
  if (process.env.HTTPS_PROXY || process.env.HTTP_PROXY || process.env.https_proxy || process.env.http_proxy) {
    undici.setGlobalDispatcher(new undici.EnvHttpProxyAgent());
  }
} catch (e) {
  // 静默退出，不影响进程启动
}
