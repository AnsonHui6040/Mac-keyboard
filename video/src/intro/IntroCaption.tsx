import { Layer, Rect, Text } from '@kinetographdev/core';
import { theme } from '../theme.ts';

/** The divider and one caption: 60 px, weight 500, centered across the divider. One line sits at y 940, two lines at 907. */
export const IntroCaption = ({ text }: { text: string }) => {
  const two = text.includes('\n');
  return (
    <Layer id="caption-area">
      <Rect id="caption-divider" {...theme.divider} fill={theme.hairline} />
      <Text id="caption" font={theme.font} weight={500} size={60} color={theme.ink} x={theme.divider.x} y={two ? 907 : 940} maxWidth={theme.divider.width} align="center" lineHeight={two ? 1.25 : 1.45}>{text}</Text>
    </Layer>
  );
};
