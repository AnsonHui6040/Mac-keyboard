import { PhoneScreen, fadeIn } from '../components/PhoneScreen.tsx';
import { MyAppsPage, NewsPage, RefreshAlert, TabBar } from './phonePages.tsx';
import type { ScreenProps } from './registry.tsx';

/** Scene 8. Beat 0: News tab, tap My Apps. Beat 1: My Apps, tap 7 DAYS. Beat 2: the refresh question. Beat 3: done. */
export const MyApps = ({ beatIndex, beatFrame }: ScreenProps) => (
  <PhoneScreen>
    {beatIndex === 0 ? <NewsPage /> : <MyAppsPage />}
    <TabBar selected={beatIndex === 0 ? 0 : 3} tapTarget={beatIndex === 0 ? { index: 3, target: 'myapps' } : undefined} />
    {beatIndex === 2 && <RefreshAlert opacity={fadeIn(beatFrame, 0, 8)} />}
  </PhoneScreen>
);
