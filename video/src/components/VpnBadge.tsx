import { Layer, Rect, Text } from '@kinetographdev/core';
import { theme } from '../theme.ts';

/** Status bar glyph, not page text: the iOS VPN pill is about 11 pt, so it sits below PHONE_MIN_TEXT like the clock digits' neighbours. */
const VPN_TEXT = 17;
export const VPN_BADGE = { x: 259, y: 19, width: 44, height: 24 } as const;

/** The iOS VPN indicator: a light pill with the letters VPN in dark ink, beside the island, left of the signal bars. */
export const VpnBadge = () => (
  <Layer id="vpn-badge">
    <Rect x={VPN_BADGE.x} y={VPN_BADGE.y} width={VPN_BADGE.width} height={VPN_BADGE.height} radius={7} fill="#f2f2f7" />
    <Text font={theme.font} weight={700} size={VPN_TEXT} color="#1c1c1e" x={VPN_BADGE.x} y={VPN_BADGE.y + 1.5} maxWidth={VPN_BADGE.width} align="center">VPN</Text>
  </Layer>
);
