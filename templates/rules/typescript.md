# TypeScript style

- `tsconfig.json`: `strict: true`, `noUncheckedIndexedAccess: true`. No exceptions.
- Forbidden: `any`, `as any`, `// @ts-ignore`. Use `unknown` and narrow.
- Prefer `interface` for object shapes; `type` only for unions, intersections, mapped types.
- Validate external input (HTTP body, env vars, JSON files) with Zod schemas.
- No `console.log` in production code paths. Use a logger (pino, winston, or platform-native).
- Async-await over raw Promise chains.
- `readonly` on fields that are not reassigned after construction.
- Imports: type imports separate (`import type { Foo }`).
- camelCase for vars/functions, PascalCase for types/classes/components.
