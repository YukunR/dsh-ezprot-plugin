import type { DefineToolOptions, ParameterSchemaSpec, StringValueSchemaSpec } from '@deepseek-ai/dsh-tools';
import { type ProteomicsService } from './service.js';
type ToolDefinitionOptions = DefineToolOptions<ParameterSchemaSpec, StringValueSchemaSpec>;
export declare function buildToolDefinitions(service: ProteomicsService): ToolDefinitionOptions[];
export {};
