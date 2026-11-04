// Capture v2 LiDAR depth maps (spec §5.2). Shared by the upload route, the
// stitch worker and purge so all three agree on the object key.

/** Depth map for frame `i`, stored beside `frame_<i>.heic` under the capture prefix. */
export const depthKeyName = (i: number): string => `depth_${i}.png`;
