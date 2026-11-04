import { Layer, Rect, Text } from '@kinetographdev/core';
import type { Rect as Box } from '../screens/geometry.ts';
import { theme } from '../theme.ts';

const { ringGap, lineWidth, lineLength, textGap, size, weight, labelLift } = theme.callout;

/**
 * A ring around the target (6 px clear of it), a horizontal line leaving the ring's right edge at the
 * target's vertical center, and a short label after the line.
 */
export const Callout = ({ id, targetRect, color, head, textColor }: { id: string; targetRect: Box; color: string; head: string; textColor?: string }) => {
  const cy = targetRect.y + targetRect.height / 2;
  const from = targetRect.x + targetRect.width + ringGap;
  const to = from + lineLength;
  return (
    <Layer id={id}>
      <Rect id={`${id}-ring`} x={targetRect.x - ringGap} y={targetRect.y - ringGap} width={targetRect.width + ringGap * 2} height={targetRect.height + ringGap * 2}
        radius={targetRect.height / 2 + ringGap} fill="#00000000" stroke={{ color, width: lineWidth }} />
      <Rect id={`${id}-line`} x={from} y={cy - lineWidth / 2} width={lineLength} height={lineWidth} fill={color} />
      <Text id={`${id}-label`} font={theme.font} weight={weight} size={size} color={textColor ?? color} x={to + textGap} y={cy - labelLift}>{head}</Text>
    </Layer>
  );
};
