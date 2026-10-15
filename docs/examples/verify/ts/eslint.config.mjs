// typescript-eslint strict, type-checked; exhaustiveness via switch-exhaustiveness-check
import tseslint from "typescript-eslint";

export default tseslint.config(
  ...tseslint.configs.strictTypeChecked,
  {
    languageOptions: { parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname } },
    rules: { "@typescript-eslint/switch-exhaustiveness-check": "error" },
  },
  { ignores: ["reports/", ".stryker-tmp/"] },
);
