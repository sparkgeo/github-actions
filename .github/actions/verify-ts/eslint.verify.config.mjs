// Fallback ESLint config for verify-ts when the project has none:
// typescript-eslint strict type-checked plus switch exhaustiveness (the
// `never` check). Resolved from the project's node_modules.
import tseslint from "typescript-eslint";

export default tseslint.config(
  ...tseslint.configs.strictTypeChecked,
  {
    languageOptions: { parserOptions: { projectService: { allowDefaultProject: ["*.js", "*.mjs"] }, tsconfigRootDir: process.cwd() } },
    rules: { "@typescript-eslint/switch-exhaustiveness-check": "error" },
  },
);
