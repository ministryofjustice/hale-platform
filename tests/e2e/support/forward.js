// Forward localhost:$HALE_TEST_PORT to nginx:443 inside the playwright
// container. The multisite's sites live at https://localhost:<port>/, and
// the container only reaches nginx by its service name, so this passes the
// raw TCP stream through: the Host header and TLS are untouched.
// Started by docker/entrypoint.sh.

const net = require("node:net");

const PORT = Number(process.env.HALE_TEST_PORT || "8443");
const TARGET_HOST = process.env.E2E_NGINX_HOST || "nginx";
const TARGET_PORT = 443;

net
  .createServer((client) => {
    const upstream = net.connect(TARGET_PORT, TARGET_HOST);
    client.pipe(upstream).pipe(client);
    client.on("error", () => upstream.destroy());
    upstream.on("error", () => client.destroy());
  })
  .listen(PORT, "127.0.0.1");
