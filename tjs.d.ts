declare module "builtin:c" {
  export const os: "windows";
  export const arch: "i386" | "x86_64";
  export const abi: "gnu" | "musl";

  type SimpleParameterMapper<T extends string> =
    T extends `` ? [] :
    T extends `${"i" | "d"}${infer next}` ? [number | void, ...ParameterMapper<next>] :
    T extends `${"s" | "w"}${infer next}` ? [string | void, ...ParameterMapper<next>] :
    T extends `v${infer next}` ? [ArrayBuffer | void, ...ParameterMapper<next>] :
    T extends `p${infer next}` ? [BigInteger | void, ...ParameterMapper<next>] :
    never;

  type ParameterMapper<T extends string> =
    T extends `` ? [] :
    T extends `${"i" | "d"}${infer next}` ? [number, ...ParameterMapper<next>] :
    T extends `${"s" | "w"}${infer next}` ? [string, ...ParameterMapper<next>] :
    T extends `v${infer next}` ? [ArrayBuffer, ...ParameterMapper<next>] :
    T extends `p${infer next}` ? [BigInteger, ...ParameterMapper<next>] :
    T extends `[${infer part}]${infer next}` ? [CallbackFunctionMapper<part>, ...ParameterMapper<next>] :
    never;

  type ResultMapper<T extends string> =
    T extends ("i" | "d") ? number :
    T extends "p" ? BigInteger :
    T extends "_" ? void :
    never;

  type CallbackFunctionMapper<T extends string> =
    T extends `${infer args}` ? (...args: SimpleParameterMapper<args>) => boolean : never;

  type FunctionMapper<T extends string> =
    T extends `${infer args}!${infer res}` ? (...args: ParameterMapper<args>) => ResultMapper<res> :
    T extends `${infer args}` ? (...args: ParameterMapper<args>) => void : never;

  export type Relocated<T extends Record<string, string>> = {
    [K in keyof T]: T[K] extends string ? FunctionMapper<T[K]> : never;
  };

  export class Compiler {
    constructor(type: "memory");
    valid: boolean;
    compile(code: string): void;
    compileFile(file: string): void;
    link(target: string): void;
    linkDir(path: string): void;
    include(path: string): void;
    sysinclude(path: string): void;
    run(...args: string[]): number;
    relocate<Recipe extends Record<string, string>>(recipe: Recipe): Relocated<Recipe>;
  }
}

declare module "builtin:io" {
  export function log(...args: any[]): void;
  export function err(...args: any[]): void;
}

declare module "builtin:utf8" {
  export function encode(string: string): ArrayBuffer;
  export function decode(buffer: ArrayBuffer): string;
}

declare module "builtin:utf16" {
  export function encode(string: string): ArrayBuffer;
  export function decode(buffer: ArrayBuffer): string;
}