/**
 * Eight replayable browser demonstrations, one per named HermesMotion semantic bundle — each starts
 * in a meaningful resting state and only animates on Replay (no autoplay, no looping). A shared
 * Reduce Motion switch, initialized from the browser/system preference, lets a reader compare both
 * contracts side by side.
 */
import React, { useEffect, useRef, useState } from 'react';
import { View, Text, Pressable, Switch, Animated, StyleSheet, AccessibilityInfo, Platform } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE, CATALOG_RADIUS } from '../tokens';
import { HERMES_MOTION_BUNDLES } from './hermesTokenProposal';

type MotionDemoId =
  | 'feedbackPress'
  | 'stateChange'
  | 'contentEnter'
  | 'contentExit'
  | 'overlayEnter'
  | 'overlayExit'
  | 'contentReposition'
  | 'scrollFollow';

interface MotionDemoDefinition {
  id: MotionDemoId;
  title: string;
  intent: string;
  bundleKey: keyof typeof HERMES_MOTION_BUNDLES;
}

const MOTION_DEMOS: MotionDemoDefinition[] = [
  { id: 'feedbackPress', title: 'Press feedback', intent: 'Acknowledges a press without delaying the action.', bundleKey: 'motion.feedback.press' },
  { id: 'stateChange', title: 'State change', intent: 'Clarifies a small change such as selection, color, or visibility.', bundleKey: 'motion.state.change' },
  { id: 'contentEnter', title: 'Content enter', intent: 'Introduces new inline content with a short fade and slide.', bundleKey: 'motion.content.enter' },
  { id: 'contentExit', title: 'Content exit', intent: 'Removes content quickly while keeping the destination understandable.', bundleKey: 'motion.content.exit' },
  { id: 'overlayEnter', title: 'Overlay enter', intent: 'Brings a temporary surface above the current context.', bundleKey: 'motion.overlay.enter' },
  { id: 'overlayExit', title: 'Overlay exit', intent: 'Returns attention from a temporary surface to the underlying context.', bundleKey: 'motion.overlay.exit' },
  { id: 'contentReposition', title: 'Content reposition', intent: 'Helps the eye follow content moving to a new stable position.', bundleKey: 'motion.content.reposition' },
  { id: 'scrollFollow', title: 'Scroll follow', intent: 'Keeps the newest streaming content in view without a disruptive jump.', bundleKey: 'motion.scroll.follow' },
];

const BROWSER_APPROXIMATION_NOTE = 'Browser demonstration; timing and compositing approximate the SwiftUI implementation.';

function useReplayAnimation(reduceMotion: boolean) {
  const progress = useRef(new Animated.Value(0)).current;
  const [playKey, setPlayKey] = useState(0);

  const replay = (durationMs: number, opacityOnly = false, onComplete?: () => void) => {
    progress.stopAnimation();
    progress.setValue(0);
    const duration = reduceMotion ? (opacityOnly ? 100 : 0) : durationMs;
    requestAnimationFrame(() => {
      // react-native-web has no native animated module — requesting the native driver there just
      // logs a console warning and silently falls back to JS-driven anyway, so it's native-only here.
      Animated.timing(progress, { toValue: 1, duration, useNativeDriver: Platform.OS !== 'web' }).start(({ finished }) => {
        if (finished) onComplete?.();
      });
      setPlayKey((k) => k + 1);
    });
  };

  return { progress, replay, playKey };
}

function ReplayButton({ title, onPress }: { title: string; onPress: () => void }) {
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${title}: Replay`}
      style={({ pressed }) => [styles.replayButton, pressed && styles.replayButtonPressed]}
    >
      <Text style={styles.replayButtonText}>Replay</Text>
    </Pressable>
  );
}

function FeedbackPressDemo({ reduceMotion, durationMs }: { reduceMotion: boolean; durationMs: number }) {
  const { progress, replay } = useReplayAnimation(reduceMotion);
  const scale = progress.interpolate({ inputRange: [0, 0.5, 1], outputRange: [1, 0.975, 1] });
  const opacity = progress.interpolate({ inputRange: [0, 0.5, 1], outputRange: [1, 0.7, 1] });
  return (
    <>
      <View style={styles.stage}>
        <Animated.View
          style={[
            styles.pressTarget,
            reduceMotion ? { opacity } : { transform: [{ scale }] },
          ]}
        >
          <Text style={styles.pressTargetText}>Send</Text>
        </Animated.View>
      </View>
      <ReplayButton title="Press feedback" onPress={() => replay(durationMs, true)} />
    </>
  );
}

function StateChangeDemo({ reduceMotion, durationMs }: { reduceMotion: boolean; durationMs: number }) {
  const { progress, replay } = useReplayAnimation(reduceMotion);
  const onOpacity = progress;
  return (
    <>
      <View style={styles.stage}>
        <View style={styles.stateChangeStack}>
          <Text style={styles.stateChangeLabel}>Off</Text>
          <Animated.Text style={[styles.stateChangeLabel, styles.stateChangeOn, { opacity: onOpacity }]}>On</Animated.Text>
        </View>
      </View>
      <ReplayButton title="State change" onPress={() => replay(durationMs)} />
    </>
  );
}

function ContentEnterDemo({ reduceMotion, durationMs }: { reduceMotion: boolean; durationMs: number }) {
  const { progress, replay } = useReplayAnimation(reduceMotion);
  const opacity = progress;
  const translateY = progress.interpolate({ inputRange: [0, 1], outputRange: [8, 0] });
  return (
    <>
      <View style={styles.stage}>
        <Animated.View style={[styles.contentCard, { opacity, transform: [{ translateY }] }]}>
          <Text style={styles.contentCardText}>New message</Text>
        </Animated.View>
      </View>
      <ReplayButton title="Content enter" onPress={() => replay(durationMs)} />
    </>
  );
}

function ContentExitDemo({ reduceMotion, durationMs }: { reduceMotion: boolean; durationMs: number }) {
  const { progress, replay } = useReplayAnimation(reduceMotion);
  const opacity = progress.interpolate({ inputRange: [0, 1], outputRange: [1, 0] });
  const translateY = progress.interpolate({ inputRange: [0, 1], outputRange: [0, 8] });
  const [exited, setExited] = useState(false);
  return (
    <>
      <View style={styles.stage}>
        {exited ? (
          <Text style={styles.placeholderText}>Content exited</Text>
        ) : (
          <Animated.View style={[styles.contentCard, { opacity, transform: [{ translateY }] }]}>
            <Text style={styles.contentCardText}>Draft message</Text>
          </Animated.View>
        )}
      </View>
      <ReplayButton
        title="Content exit"
        onPress={() => {
          setExited(false);
          replay(durationMs, false, () => setExited(true));
        }}
      />
    </>
  );
}

function OverlayEnterDemo({ reduceMotion, durationMs }: { reduceMotion: boolean; durationMs: number }) {
  const { progress, replay } = useReplayAnimation(reduceMotion);
  const opacity = progress;
  const scale = progress.interpolate({ inputRange: [0, 1], outputRange: [0.95, 1] });
  return (
    <>
      <View style={styles.stage}>
        <Animated.View style={[styles.overlayCard, { opacity, transform: [{ scale }] }]}>
          <Text style={styles.contentCardText}>Approve action?</Text>
        </Animated.View>
      </View>
      <ReplayButton title="Overlay enter" onPress={() => replay(durationMs)} />
    </>
  );
}

function OverlayExitDemo({ reduceMotion, durationMs }: { reduceMotion: boolean; durationMs: number }) {
  const { progress, replay } = useReplayAnimation(reduceMotion);
  const opacity = progress.interpolate({ inputRange: [0, 1], outputRange: [1, 0] });
  const scale = progress.interpolate({ inputRange: [0, 1], outputRange: [1, 0.95] });
  const [closed, setClosed] = useState(false);
  return (
    <>
      <View style={styles.stage}>
        {closed ? (
          <Text style={styles.placeholderText}>Overlay closed</Text>
        ) : (
          <Animated.View style={[styles.overlayCard, { opacity, transform: [{ scale }] }]}>
            <Text style={styles.contentCardText}>Approve action?</Text>
          </Animated.View>
        )}
      </View>
      <ReplayButton
        title="Overlay exit"
        onPress={() => {
          setClosed(false);
          replay(durationMs, false, () => setClosed(true));
        }}
      />
    </>
  );
}

function ContentRepositionDemo({ reduceMotion, durationMs }: { reduceMotion: boolean; durationMs: number }) {
  const { progress, replay } = useReplayAnimation(reduceMotion);
  const translateX = progress.interpolate({ inputRange: [0, 1], outputRange: [-24, 24] });
  return (
    <>
      <View style={styles.stage}>
        <View style={styles.repositionGuideRow}>
          <View style={styles.repositionGuide} />
          <View style={styles.repositionGuide} />
        </View>
        <Animated.View style={[styles.repositionItem, { transform: [{ translateX }] }]} />
      </View>
      <ReplayButton title="Content reposition" onPress={() => replay(durationMs)} />
    </>
  );
}

function ScrollFollowDemo({ reduceMotion, durationMs }: { reduceMotion: boolean; durationMs: number }) {
  const { progress, replay } = useReplayAnimation(reduceMotion);
  const translateY = progress.interpolate({ inputRange: [0, 1], outputRange: [-24, 24] });
  return (
    <>
      <View style={[styles.stage, styles.transcriptStage]}>
        <Animated.View style={[styles.scrollMarker, { transform: [{ translateY }] }]} />
      </View>
      <ReplayButton title="Scroll follow" onPress={() => replay(durationMs)} />
    </>
  );
}

const DEMO_COMPONENTS: Record<MotionDemoId, React.ComponentType<{ reduceMotion: boolean; durationMs: number }>> = {
  feedbackPress: FeedbackPressDemo,
  stateChange: StateChangeDemo,
  contentEnter: ContentEnterDemo,
  contentExit: ContentExitDemo,
  overlayEnter: OverlayEnterDemo,
  overlayExit: OverlayExitDemo,
  contentReposition: ContentRepositionDemo,
  scrollFollow: ScrollFollowDemo,
};

function MotionDemoCard({ demo, reduceMotion }: { demo: MotionDemoDefinition; reduceMotion: boolean }) {
  const bundle = HERMES_MOTION_BUNDLES[demo.bundleKey];
  const Demo = DEMO_COMPONENTS[demo.id];
  return (
    <View style={styles.card}>
      <Text style={styles.cardTitle}>{demo.title}</Text>
      <Text style={styles.cardIntent}>{demo.intent}</Text>
      <Demo reduceMotion={reduceMotion} durationMs={bundle.durationMs} />
      <Text style={styles.cardMeta}>{bundle.durationMs}ms · {bundle.easing} easing{bundle.detail ? ` · ${bundle.detail}` : ''}</Text>
    </View>
  );
}

export function HermesMotionReference() {
  const [reduceMotion, setReduceMotion] = useState(false);

  useEffect(() => {
    let mounted = true;
    AccessibilityInfo.isReduceMotionEnabled().then((enabled) => {
      if (mounted) setReduceMotion(enabled);
    });
    return () => {
      mounted = false;
    };
  }, []);

  return (
    <View style={styles.stack}>
      <View style={styles.motionModeRow}>
        <Text style={styles.motionModeLabel}>Reduce Motion</Text>
        <Switch
          value={reduceMotion}
          onValueChange={setReduceMotion}
          accessibilityLabel="Reduce Motion"
        />
      </View>
      <View style={styles.cardGrid}>
        {MOTION_DEMOS.map((demo) => (
          <MotionDemoCard key={demo.id} demo={demo} reduceMotion={reduceMotion} />
        ))}
      </View>
      <Text style={styles.approximationNote}>{BROWSER_APPROXIMATION_NOTE}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  stack: { gap: CATALOG_SPACE.lg },
  motionModeRow: { flexDirection: 'row', alignItems: 'center', gap: CATALOG_SPACE.sm },
  motionModeLabel: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.text },
  cardGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: CATALOG_SPACE.md },
  card: {
    width: 260, gap: CATALOG_SPACE.xs, padding: CATALOG_SPACE.md,
    borderRadius: CATALOG_RADIUS.md, borderWidth: StyleSheet.hairlineWidth, borderColor: CATALOG_COLOR.border,
    backgroundColor: CATALOG_COLOR.surfaceMuted,
  },
  cardTitle: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.text },
  cardIntent: { fontSize: CATALOG_TYPE.xs, color: CATALOG_COLOR.textMuted, lineHeight: 15 },
  cardMeta: { fontSize: 10, color: CATALOG_COLOR.textMuted, fontFamily: CATALOG_COLOR.code },
  stage: {
    height: 72, borderRadius: CATALOG_RADIUS.sm, backgroundColor: CATALOG_COLOR.surface,
    borderWidth: StyleSheet.hairlineWidth, borderColor: CATALOG_COLOR.border,
    alignItems: 'center', justifyContent: 'center', overflow: 'hidden',
  },
  transcriptStage: { justifyContent: 'flex-start', paddingTop: 8 },
  pressTarget: { paddingHorizontal: CATALOG_SPACE.md, paddingVertical: CATALOG_SPACE.sm, borderRadius: 999, backgroundColor: CATALOG_COLOR.accent },
  pressTargetText: { color: '#ffffff', fontWeight: '700', fontSize: CATALOG_TYPE.sm },
  stateChangeStack: { width: 64, height: 32, alignItems: 'center', justifyContent: 'center' },
  stateChangeLabel: { position: 'absolute', fontSize: CATALOG_TYPE.md, fontWeight: '700', color: CATALOG_COLOR.textMuted },
  stateChangeOn: { color: CATALOG_COLOR.accent },
  contentCard: { paddingHorizontal: CATALOG_SPACE.md, paddingVertical: CATALOG_SPACE.sm, borderRadius: CATALOG_RADIUS.sm, backgroundColor: CATALOG_COLOR.chip },
  contentCardText: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.text },
  overlayCard: { paddingHorizontal: CATALOG_SPACE.lg, paddingVertical: CATALOG_SPACE.md, borderRadius: CATALOG_RADIUS.md, backgroundColor: CATALOG_COLOR.surface, borderWidth: 1, borderColor: CATALOG_COLOR.border },
  placeholderText: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, fontStyle: 'italic' },
  repositionGuideRow: { position: 'absolute', flexDirection: 'row', justifyContent: 'space-between', width: '80%' },
  repositionGuide: { width: 8, height: 8, borderRadius: 4, backgroundColor: CATALOG_COLOR.border },
  repositionItem: { width: 16, height: 16, borderRadius: 8, backgroundColor: CATALOG_COLOR.accent },
  scrollMarker: { width: 40, height: 8, borderRadius: 4, backgroundColor: CATALOG_COLOR.accent },
  replayButton: { alignSelf: 'flex-start', paddingHorizontal: CATALOG_SPACE.md, paddingVertical: CATALOG_SPACE.xs, borderRadius: CATALOG_RADIUS.sm, borderWidth: 1, borderColor: CATALOG_COLOR.accent },
  replayButtonPressed: { opacity: 0.7 },
  replayButtonText: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.accent },
  approximationNote: { fontSize: CATALOG_TYPE.xs, color: CATALOG_COLOR.textMuted, fontStyle: 'italic' },
});
