import { Text } from '@kinetographdev/core';
import { theme } from '../theme.ts';

/** Top-left device label, e.g. 在 Mac 上. */
export const DeviceTag = ({ label }: { label: string }) => (
  <Text id="device" font={theme.font} weight={theme.deviceTag.weight} size={theme.deviceTag.size} color={theme.muted} x={theme.deviceTag.x} y={theme.deviceTag.y}>
    {label}
  </Text>
);
