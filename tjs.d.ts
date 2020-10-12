declare module "builtin:c" {
  export const os: "windows";
  export const arch: "i386" | "x86_64";
  export const abi: "gnu";
  export type SupportedType =
    | "integer"
    | "double"
    | "string";
  export interface BasicRecipeItem {
    arguments: SupportedType[];
    result?: SupportedType;
  }
  type TypeMap<T extends SupportedType | void> =
    T extends "integer" | "double" ? number :
    T extends "string" ? string :
    T extends void ? void :
    never;
  type MMap<T> = T;
  type TypeArrayMap<T extends SupportedType[]> = {
    [K in keyof T]: T[K] extends SupportedType ? TypeMap<T[K]> : never;
  };
  type FunctionMap<T extends SupportedType[], R extends SupportedType | void> = (...args: TypeArrayMap<T>) => TypeMap<R>;
  export type Relocated<T extends Record<string, BasicRecipeItem>> = {
    [K in keyof T]: T[K] extends BasicRecipeItem ? FunctionMap<T[K]["arguments"], T[K]["result"]> : never;
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
    relocate<Recipe extends Record<string, BasicRecipeItem>>(recipe: Recipe): Relocated<Recipe>;
  }
}