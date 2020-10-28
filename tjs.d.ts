declare interface ImportMeta {
  readonly url: string;
  readonly main: string | undefined;
}

declare module "builtin:c" {
  export const os: "windows" | "linux";
  export const arch: "i386" | "x86_64" | "aarch64";
  export const abi: "gnu" | "musl";

  /** Append to library search paths */
  export function appendLibSearchPath(path: string): boolean;

  /** The core compiler */
  export class Compiler {
    /** Construct compiler, specify output type, only type=memory can be used to run or relocate */
    constructor(type: "memory" | "exe" | "dll" | "obj" | "preprocessor");
    /** Check if it is a valid compiler */
    get valid(): boolean;
    /** Add compiler option */
    option(opt: String): void
    /** Compile a string containing a C source */
    compile(code: string): void;
    /** Add a file (C file, dll, object, library, ld script) */
    add(file: string): void;
    /** Link library */
    link(target: string): void;
    /** Library search path */
    linkDir(path: string): void;
    /** Include search path */
    include(path: string): void;
    /** System include search path */
    sysinclude(path: string): void;
    /** Output an executable, library or object file. DO NOT call relocate before. */
    output(path: string): void;
    /** Link and run main() function and return its value. DO NOT call relocate before. */
    run(...args: string[]): number;
    /** Do all relocations and returns relocated symbols */
    relocate<Recipe extends Record<string, string>>(recipe: Recipe): Relocated<Recipe>;
  }

  type SimpleParameterMapper<T extends string> =
    T extends `` ? [] :
    T extends `${"i" | "d"}${infer next}` ? [number, ...SimpleParameterMapper<next>] :
    T extends `${"s" | "w"}${infer next}` ? [string, ...SimpleParameterMapper<next>] :
    T extends `v${infer next}` ? [ArrayBuffer, ...SimpleParameterMapper<next>] :
    T extends `b${infer next}` ? [bigint, ...SimpleParameterMapper<next>] :
    T extends `p${infer next}` ? [bigint, ...SimpleParameterMapper<next>] :
    never;

  type ParameterMapper<T extends string> =
    T extends `` ? [] :
    T extends `${"i" | "d"}${infer next}` ? [number, ...ParameterMapper<next>] :
    T extends `${"s" | "w"}${infer next}` ? [string, ...ParameterMapper<next>] :
    T extends `v${infer next}` ? [ArrayBuffer, ...ParameterMapper<next>] :
    T extends `b${infer next}` ? [bigint, ...ParameterMapper<next>] :
    T extends `p${infer next}` ? [bigint, ...ParameterMapper<next>] :
    T extends `[${infer part}]${infer next}` ? [CallbackFunctionMapper<part>, ...ParameterMapper<next>] :
    never;

  type ResultMapper<T extends string> =
    T extends ("i" | "d") ? number :
    T extends ("b" | "p") ? bigint :
    T extends "_" ? void :
    never;

  type CallbackFunctionMapper<T extends string> =
    T extends `${infer args}` ? (...args: SimpleParameterMapper<args>) => number | void : never;

  type FunctionMapper<T extends string> =
    T extends `${infer args}!${infer res}` ? (...args: ParameterMapper<args>) => ResultMapper<res> :
    T extends `${infer args}` ? (...args: ParameterMapper<args>) => void : never;

  export type Relocated<T extends Record<string, string>> = {
    [K in keyof T]: T[K] extends string ? FunctionMapper<T[K]> : never;
  };
}

declare module "builtin:io" {
  /**
   * Output to stdout
   * @param args output content
   */
  export function log(...args: any[]): void;
  /**
   * Output to stderr
   * @param args output content
   */
  export function err(...args: any[]): void;

  /**
   * Like log, but won't append \n
   * @param args output content
   */
  export function print(...args: any[]): void;
  /**
   * Like err, but won't append \n
   * @param args output content
   */
  export function errprint(...args: any[]): void;
}

declare module "builtin:utf8" {
  export function encode(string: string): ArrayBuffer;
  export function decode(buffer: ArrayBuffer): string;
}

declare module "builtin:utf16" {
  export function encode(string: string): ArrayBuffer;
  export function decode(buffer: ArrayBuffer): string;
}