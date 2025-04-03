import { type JestConfigWithTsJest, pathsToModuleNameMapper } from "ts-jest";

const config: JestConfigWithTsJest = {
  watch: false,
  preset: "ts-jest/presets/js-with-ts",
  testEnvironment: "node",
  testTimeout: 10000,
  globalSetup: "./jest.setup.ts",
  globalTeardown: "./jest.teardown.ts",
  transform: {
    // '^.+\\.[tj]sx?$' to process js/ts with ts-jest
    // '^.+\\.m?[tj]sx?$' to process js/ts/mjs/mts with ts-jest
    "^.+\\.tsx?$": [
      "ts-jest",
      {
        tsconfig: "./tsconfig.json",
      },
    ],
  },
  moduleNameMapper: pathsToModuleNameMapper({
    "@declarations": ["./declarations"],
    "@declarations/*": ["./declarations/*"],
    "@fe": ["./frontend"],
    "@fe/*": ["./frontend/*"]
  }, {
    prefix: "<rootDir>",
  }),
};

export default config;
