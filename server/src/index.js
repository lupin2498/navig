import { createApp } from './server.js';

const port = Number(process.env.PORT) || 8080;
const host = process.env.HOST || '0.0.0.0';
const dataDir = process.env.DATA_DIR || './data';
const historyHours = Number(process.env.HISTORY_HOURS) || 24;

const app = createApp({ dataDir, historyHours });

app.server.listen(port, host, () => {
  console.log(`Navig server listening on http://${host}:${port} (data: ${dataDir})`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    console.log(`${signal} received, shutting down`);
    await app.close();
    process.exit(0);
  });
}
