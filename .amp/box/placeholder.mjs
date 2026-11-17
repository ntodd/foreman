// Answers on the deployment's public URL. Foreman itself listens only on
// loopback and is served on the tailnet (start.sh).
import { createServer } from 'node:http'

createServer((_req, res) => {
	res.writeHead(404, { 'content-type': 'text/plain' })
	res.end('Foreman is only reachable on the tailnet.\n')
}).listen(Number(process.env.PORT), '0.0.0.0')
