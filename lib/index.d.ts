import Schema from '@deepseek-ai/schemastery';
import type { Context } from '@deepseek-ai/cordis';
export declare const name = "ezprot";
export declare const inject: string[];
export interface Config {
    dataDir: string;
    libraryDir: string;
    rscript: string;
    cranRepo: string;
    biocRepo: string;
    enableInstall: boolean;
    defaultTimeoutMs: number;
    backend: string;
    dockerImage: string;
}
export declare const Config: Schema<Schemastery.ObjectS<{
    dataDir: Schema<string, string>;
    libraryDir: Schema<string, string>;
    rscript: Schema<string, string>;
    cranRepo: Schema<string, string>;
    biocRepo: Schema<string, string>;
    enableInstall: Schema<boolean, boolean>;
    defaultTimeoutMs: Schema<number, number>;
    backend: Schema<string, string>;
    dockerImage: Schema<string, string>;
}>, Schemastery.ObjectT<{
    dataDir: Schema<string, string>;
    libraryDir: Schema<string, string>;
    rscript: Schema<string, string>;
    cranRepo: Schema<string, string>;
    biocRepo: Schema<string, string>;
    enableInstall: Schema<boolean, boolean>;
    defaultTimeoutMs: Schema<number, number>;
    backend: Schema<string, string>;
    dockerImage: Schema<string, string>;
}>>;
export declare function apply(ctx: Context, config: Config): void;
