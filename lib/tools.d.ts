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
export declare function buildToolDefinitions(service: ProteomicsService, registerImage?: ImageRegistrar): ToolDefinitionOptions[];
export {};
