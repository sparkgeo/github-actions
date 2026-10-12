// Tiny static page for the Playwright fixture; playwright.config.js starts it
// as the webServer when BASE_URL is not set.
import http from 'node:http';

const port = Number(process.env.PORT || 4173);
http
  .createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end('<!doctype html><html><head><title>Fixture app</title></head><body><h1>Hello from the fixture</h1><a href="/about">About</a></body></html>');
  })
  .listen(port, '127.0.0.1', () => console.log(`fixture server on http://127.0.0.1:${port}`));
