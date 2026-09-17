// 固定服务器配置：App 只能连接该服务器，地址不可修改、连接不可删除。
// 注意：更改此处需重新构建并上架（证书固定 + 硬编码地址）。
export const DEFAULT_GATEWAY_SCHEME: string = 'https';
export const DEFAULT_GATEWAY_HOST: string = '8.153.174.88';
export const DEFAULT_GATEWAY_PORT: number = 8443;
export const DEFAULT_GATEWAY_DISPLAY: string = `${DEFAULT_GATEWAY_HOST}:${DEFAULT_GATEWAY_PORT}`;
export const DEFAULT_GATEWAY_NAME: string = 'AIRouter';
