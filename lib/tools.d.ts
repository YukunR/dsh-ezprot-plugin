import type { DefineToolOptions, ParameterSchemaSpec } from '@deepseek-ai/dsh-tools';
import { type ProteomicsService } from './service.js';
type ToolDefinitionOptions = DefineToolOptions<ParameterSchemaSpec, any>;
/** Structural image reference compatible with @deepseek-ai/dsh-attachment. */
export interface ImageRefLike {
    attachmentId: string;
    mediaType: 'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif';
    bytes: number;
    width: number;
    height: number;
    name?: string;
}
/** Registers a PNG with the attachment service so the chat can show it. */
export type ImageRegistrar = (absPath: string, name?: string) => Promise<ImageRefLike | null>;
/** Structural view of the harness jobs registry (ctx.jobs). */
export interface JobsProvider {
    start(spec: {
        kind: 'ezprot-setup';
        label: string;
        owner?: unknown;
        run: () => {
            cancel: (reason?: string) => void;
            done: Promise<{
                status: 'completed' | 'killed' | 'failed';
                detail?: string;
                output?: string;
            }>;
            readOutput?: () => string;
        };
    }): string;
}
export type GetJobs = () => JobsProvider | undefined;
export declare function buildToolDefinitions(service: ProteomicsService, registerImage?: ImageRegistrar, getJobs?: GetJobs): ToolDefinitionOptions[];
export {};
