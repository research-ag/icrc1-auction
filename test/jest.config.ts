import { type JestConfigWithTsJest, pathsToModuleNameMapper } from "ts-jest";

import { compilerOptions } from "../tsconfig.json";

const config: JestConfigWithTsJest = {
  watch: false,
  preset: "ts-jest/presets/js-with-ts",
  testEnvironment: "node",
  testTimeout: 10000,
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
  moduleNameMapper: pathsToModuleNameMapper(compilerOptions.paths, {
    prefix: "<rootDir>",
  }),
};

export default config;
