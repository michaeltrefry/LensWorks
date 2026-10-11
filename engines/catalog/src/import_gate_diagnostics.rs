//! Bounded, default-off observation. This supplies no wake, admission or retirement authority.
#[cfg(not(feature = "import-timing-fixture"))]
mod disabled {
    pub(crate) struct GateProbe;
    impl GateProbe {
        pub(crate) fn start() -> Self { Self }
        pub(crate) fn condition(&mut self, _: usize, _: bool) {}
        pub(crate) fn finish(self, _: bool) {}
    }
    pub(crate) struct RenderReady;
    impl RenderReady {
        pub(crate) fn start() -> Self { Self }
        pub(crate) fn collected(self) {}
    }
    pub(crate) fn consumed(_: u64, _: u64, _: std::time::Instant) {}
    pub(crate) fn abandoned(_: u64, _: u64) {}
    #[cfg(test)]
    mod tests {
        #[test]
        fn gate_discriminator_default_off_has_zero_sized_probes_and_no_authority() {
            assert_eq!(std::mem::size_of::<super::GateProbe>(), 0);
            assert_eq!(std::mem::size_of::<super::RenderReady>(), 0);
            let mut probe = super::GateProbe::start();
            probe.condition(0, false); probe.finish(false);
            super::RenderReady::start().collected();
            super::consumed(1, 1, std::time::Instant::now());
        }
    }
}
#[cfg(not(feature = "import-timing-fixture"))]
pub(crate) use disabled::*;

#[cfg(feature = "import-timing-fixture")]
mod enabled {
    use std::{sync::Mutex, time::Instant};
    const LIMITS: [u64; 6] = [100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000, u64::MAX];
    const REASONS: [&str; 7] = ["read_active", "delivery_io", "delivery_pending", "scheduler_active", "scheduler_queued", "launch_pause", "external_native"];
    const ROWS: [&str; 2] = ["render_result_ready_to_poll_join", "first_safe_gate_to_matching_consume"];
    #[derive(Clone, Copy)]
    struct Row { count: u64, sum: u64, max: u64, buckets: [u64; 6], saturated: bool }
    impl Row {
        const fn new() -> Self { Self { count: 0, sum: 0, max: 0, buckets: [0; 6], saturated: false } }
        fn add(&mut self, ns: u64) {
            self.saturated |= self.count == u64::MAX || self.sum.checked_add(ns).is_none();
            self.count = self.count.saturating_add(1); self.sum = self.sum.saturating_add(ns); self.max = self.max.max(ns);
            let index = LIMITS.iter().position(|limit| ns <= *limit).unwrap();
            self.saturated |= self.buckets[index] == u64::MAX;
            self.buckets[index] = self.buckets[index].saturating_add(1);
        }
    }
    struct Clear { sequence: u64, at: Instant }
    struct State {
        epoch: u64, first_blocker: [u64; 7], checked: u64, passed: u64,
        no_prepared_at_entry: u64, unmatched_consume: u64, abandoned_clear: u64, invalid_clock: u64,
        saturated: bool, clear: Option<Clear>, rows: [Row; 2],
    }
    impl State {
        const fn new() -> Self { Self { epoch: 0, first_blocker: [0; 7], checked: 0, passed: 0,
            no_prepared_at_entry: 0, unmatched_consume: 0, abandoned_clear: 0, invalid_clock: 0, saturated: false,
            clear: None, rows: [Row::new(); 2] } }
        fn enter(&mut self, epoch: u64) -> bool {
            if epoch == 0 { return false }
            if self.epoch != epoch { *self = Self::new(); self.epoch = epoch; }
            true
        }
        fn increment(value: &mut u64, saturated: &mut bool) {
            *saturated |= *value == u64::MAX; *value = value.saturating_add(1);
        }
        fn gate(&mut self, sequence: Option<u64>, first: Option<usize>, safe: bool, at: Instant) {
            let Some(sequence) = sequence else {
                Self::increment(&mut self.no_prepared_at_entry, &mut self.saturated); return
            };
            Self::increment(&mut self.checked, &mut self.saturated);
            if safe {
                Self::increment(&mut self.passed, &mut self.saturated);
                if self.clear.as_ref().is_none_or(|clear| clear.sequence != sequence) {
                    self.clear = Some(Clear { sequence, at });
                }
            } else if let Some(first) = first {
                Self::increment(&mut self.first_blocker[first], &mut self.saturated);
            }
        }
        fn elapsed(&mut self, row: usize, start: Instant, end: Instant) {
            if let Some(elapsed) = end.checked_duration_since(start) {
                self.rows[row].add(u64::try_from(elapsed.as_nanos()).unwrap_or(u64::MAX));
            } else { Self::increment(&mut self.invalid_clock, &mut self.saturated); }
        }
        fn consume(&mut self, sequence: u64, at: Instant) {
            if self.clear.as_ref().is_some_and(|clear| clear.sequence == sequence) {
                let clear = self.clear.take().unwrap(); self.elapsed(1, clear.at, at);
            } else { Self::increment(&mut self.unmatched_consume, &mut self.saturated); }
        }
        fn abandon(&mut self, sequence: u64) {
            if self.clear.as_ref().is_some_and(|clear| clear.sequence == sequence) {
                self.clear = None; Self::increment(&mut self.abandoned_clear, &mut self.saturated);
            }
        }
        fn json(&self) -> serde_json::Value {
            serde_json::json!({"schema":1,"scope":"fixture_only_first_blocker_and_joined_render_observation",
                "epoch":self.epoch,"first_blocker_order":REASONS,"first_blocker_counts":self.first_blocker,
                "checked_prepared_at_entry":self.checked,"passed_prepared_at_entry":self.passed,
                "no_prepared_at_entry":self.no_prepared_at_entry,"unmatched_consume":self.unmatched_consume,
                "abandoned_clear":self.abandoned_clear,"invalid_clock":self.invalid_clock,"saturated":self.saturated,
                "unfinished_clear_sequence":self.clear.as_ref().map(|clear| clear.sequence),
                "bucket_upper_ns":LIMITS,
                "rows":ROWS.iter().zip(&self.rows).map(|(name,row)| serde_json::json!({"name":name,
                    "values":[row.count,row.sum,row.max,row.buckets,row.saturated]})).collect::<Vec<_>>(),
                "limits":"First blocker only, later predicates unobserved. Safe is sampled, not continuously clear. Ready means work returned, not thread exit or retirement. Only checked poll/join collection is timed; shutdown and unfinished work omitted. Inclusive concurrent walltime, not CPU, additive cost or avoidable fraction."})
        }
    }
    static STATE: Mutex<State> = Mutex::new(State::new());
    fn current<R>(call: impl FnOnce(&mut State) -> R) -> Option<(u64, R)> {
        // Same existing exact feature/fixture/readiness opt-in and epoch. No new flag.
        let (epoch, _) = crate::import_readiness::pending_sequence()?;
        let mut state = STATE.lock().unwrap_or_else(|error| error.into_inner());
        if crate::import_timing::current_fixture_epoch() != epoch || !state.enter(epoch) { return None }
        Some((epoch, call(&mut state)))
    }
    fn matching(epoch: u64, call: impl FnOnce(&mut State)) {
        if epoch == 0 || crate::import_timing::current_fixture_epoch() != epoch { return }
        let mut state = STATE.lock().unwrap_or_else(|error| error.into_inner());
        if state.epoch == epoch && crate::import_timing::current_fixture_epoch() == epoch { call(&mut state) }
    }
    pub(crate) struct GateProbe { key: Option<(u64, Option<u64>)>, first: Option<usize> }
    impl GateProbe {
        pub(crate) fn start() -> Self {
            let key = crate::import_readiness::pending_sequence();
            if let Some((epoch, _)) = key {
                let mut state = STATE.lock().unwrap_or_else(|error| error.into_inner());
                if crate::import_timing::current_fixture_epoch() == epoch { state.enter(epoch); }
            }
            Self { key, first: None }
        }
        pub(crate) fn condition(&mut self, index: usize, clear: bool) {
            if !clear && self.first.is_none() { self.first = Some(index); }
        }
        pub(crate) fn finish(self, safe: bool) {
            if let Some((epoch, sequence)) = self.key {
                matching(epoch, |state| state.gate(sequence, self.first, safe, Instant::now()));
            }
        }
    }
    pub(crate) struct RenderReady { key: Option<(u64, Instant)> }
    impl RenderReady {
        pub(crate) fn start() -> Self {
            Self { key: current(|_| Instant::now()).map(|(epoch, at)| (epoch, at)) }
        }
        pub(crate) fn collected(self) {
            if let Some((epoch, at)) = self.key { matching(epoch, |state| state.elapsed(0, at, Instant::now())); }
        }
    }
    pub(crate) fn consumed(epoch: u64, sequence: u64, at: Instant) {
        matching(epoch, |state| state.consume(sequence, at));
    }
    pub(crate) fn abandoned(epoch: u64, sequence: u64) {
        matching(epoch, |state| state.abandon(sequence));
    }
    pub(crate) fn snapshot() -> Option<serde_json::Value> {
        current(|state| {
            // Null means no observation captured; no populated field is discarded.
            (state.checked != 0 || state.no_prepared_at_entry != 0 || state.unmatched_consume != 0
                || state.abandoned_clear != 0 || state.invalid_clock != 0 || state.rows.iter().any(|row| row.count != 0))
                .then(|| state.json())
        }).and_then(|(_, value)| value)
    }
    pub(crate) fn metadata_layouts() -> [(usize, usize); 2] {
        [(std::mem::size_of::<RenderReady>(), std::mem::align_of::<RenderReady>()),
         (std::mem::size_of::<Mutex<State>>(), std::mem::align_of::<Mutex<State>>())]
    }
    #[cfg(test)]
    pub(crate) fn maximal_serialization_fixture() -> bool {
        current(|state| {
            state.first_blocker = [u64::MAX; 7]; state.checked = u64::MAX; state.passed = u64::MAX;
            state.no_prepared_at_entry = u64::MAX; state.unmatched_consume = u64::MAX;
            state.invalid_clock = u64::MAX; state.abandoned_clear = u64::MAX; state.saturated = true;
            state.clear = Some(Clear { sequence: u64::MAX, at: Instant::now() });
            state.rows = [Row { count: u64::MAX, sum: u64::MAX, max: u64::MAX,
                buckets: [u64::MAX; 6], saturated: true }; 2];
        }).is_some()
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::time::Duration;
        fn active() -> State { let mut s=State::new(); assert!(s.enter(1)); s }
        #[test] fn gate_discriminator_first_blocker_partition_and_no_pending_are_separate() {
            let mut s=active(); let now=Instant::now();
            for i in 0..7 { s.gate(Some(i as u64+1),Some(i),false,now); }
            s.gate(Some(9),None,true,now); s.gate(None,Some(0),false,now);
            assert_eq!(s.first_blocker,[1;7]); assert_eq!(s.checked,8); assert_eq!(s.passed,1);
            assert_eq!(s.no_prepared_at_entry,1);
        }
        #[test] fn gate_discriminator_first_safe_sample_is_not_overwritten_and_consumes_once() {
            let mut s=active(); let now=Instant::now();
            s.gate(Some(1),None,true,now); s.gate(Some(1),None,true,now+Duration::from_nanos(4));
            s.consume(1,now+Duration::from_nanos(10)); s.consume(1,now+Duration::from_nanos(20));
            assert_eq!(s.rows[1].count,1); assert_eq!(s.rows[1].sum,10); assert_eq!(s.unmatched_consume,1);
        }
        #[test] fn gate_discriminator_unfinished_cancel_and_new_sequence_do_not_mint_duration() {
            let mut s=active(); let now=Instant::now(); s.gate(Some(1),None,true,now);
            s.consume(2,now); assert_eq!(s.rows[1].count,0); assert_eq!(s.unmatched_consume,1);
            assert_eq!(s.json()["unfinished_clear_sequence"],1);
            s.abandon(2); assert!(s.clear.is_some());
            s.abandon(1); assert!(s.clear.is_none()); assert_eq!(s.abandoned_clear,1);
            s.gate(Some(2),None,true,now+Duration::from_nanos(3));
            s.consume(2,now+Duration::from_nanos(8)); assert_eq!(s.rows[1].sum,5);
        }
        #[test] fn gate_discriminator_epoch_reset_discards_clear_and_completed_rows() {
            let mut s=active(); let now=Instant::now(); s.gate(Some(1),None,true,now);s.elapsed(0,now,now);
            assert!(s.enter(2)); assert!(s.clear.is_none()); assert_eq!(s.rows[0].count,0);
            assert_eq!(s.first_blocker,[0;7]); assert!(!s.enter(0)); assert_eq!(s.epoch,2);
        }
        #[test] fn gate_discriminator_bucket_edges_saturation_and_invalid_clock_are_bounded() {
            let mut s=active(); let now=Instant::now();
            for (i,edge) in LIMITS[..5].iter().enumerate() {
                s.rows[0].add(*edge); assert_eq!(s.rows[0].buckets[i],1);
            }
            s.rows[0].add(u64::MAX);s.rows[0].add(1);
            assert!(s.rows[0].saturated); assert_eq!(s.rows[0].sum,u64::MAX);
            s.elapsed(1,now+Duration::from_nanos(1),now); assert_eq!(s.invalid_clock,1); assert_eq!(s.rows[1].count,0);
        }
        #[test] fn gate_discriminator_same_fixed_json_shapes_do_not_infer_lifecycle() {
            let s=active(); let value=s.json();assert_eq!(value["first_blocker_counts"].as_array().unwrap().len(),7);
            assert_eq!(value["rows"].as_array().unwrap().len(),2);
            for row in value["rows"].as_array().unwrap() {
                assert_eq!(row["values"].as_array().unwrap().len(),5);
                assert_eq!(row["values"][3].as_array().unwrap().len(),6);
            }
            assert!(value["limits"].as_str().unwrap().contains("not thread exit or retirement"));
        }
    }
}
#[cfg(feature = "import-timing-fixture")]
pub(crate) use enabled::*;
