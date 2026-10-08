//! Fixture-only observation of finalized producer events and actor wait boundaries.
//! This does not change the rendezvous channel, wake/queue predicate or safe gate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(usize)]
pub(crate) enum Kind { Begun, Header, Source, End, Skipped, Failed, Finished }

#[cfg(not(feature = "import-timing-fixture"))]
mod disabled {
    pub(crate) struct Ready;
    pub(crate) struct Wait;
    pub(crate) fn ready(_: super::Kind) -> Ready { Ready }
    impl Ready { pub(crate) fn finish(self, _: bool) {} }
    pub(crate) fn wait() -> Wait { Wait }
    pub(crate) fn poll<T>(call: impl FnOnce() -> Result<T, std::sync::mpsc::TryRecvError>, _: impl FnOnce(&T) -> super::Kind) -> Result<T, std::sync::mpsc::TryRecvError> { call() }
    pub(crate) fn gate(_: bool) {}
}
#[cfg(not(feature = "import-timing-fixture"))]
pub(crate) use disabled::*;

#[cfg(feature = "import-timing-fixture")]
mod enabled {
    use super::Kind;
    use std::sync::Mutex;
    use std::time::Instant;
    const LIMITS: [u64; 6] = [100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000, u64::MAX];
    const ROWS: [&str; 18] = ["prepared_event", "wait_enter_prepared", "wait_enter_clear", "prepared_during_wait_to_wait_exit",
        "poll_empty_prepared", "poll_empty_clear", "prepared_to_consumed", "untracked_consumed", "kind_mismatch",
        "send_ok_after_consumed", "send_ok_without_observed_consume", "send_error_before_consume", "unwound_send", "overlapping_guard", "poll_disconnected", "safe_gate_checked_prepared", "safe_gate_blocked_prepared", "safe_gate_passed_prepared"];
    const KINDS: [&str; 7] = ["begun", "header", "source", "end", "skipped", "failed", "finished"];
    #[derive(Clone, Copy)]
    struct Row { count: u64, sum: u64, max: u64, buckets: [u64; 6], saturated: bool }
    impl Row {
        const fn new() -> Self { Self { count: 0, sum: 0, max: 0, buckets: [0; 6], saturated: false } }
        fn add(&mut self, elapsed: u64) {
            self.saturated |= self.count == u64::MAX || self.sum.checked_add(elapsed).is_none();
            self.count = self.count.saturating_add(1); self.sum = self.sum.saturating_add(elapsed); self.max = self.max.max(elapsed);
            let i = LIMITS.iter().position(|limit| elapsed <= *limit).unwrap();
            self.saturated |= self.buckets[i] == u64::MAX;
            self.buckets[i] = self.buckets[i].saturating_add(1);
        }
    }
    struct Pending { sequence: u64, kind: Kind, start: Instant }
    struct Waiting { sequence: u64, start: Instant, prepared_at_entry: bool, first_prepared_during: Option<Instant> }
    struct State {
        epoch: u64, enabled: bool, sequence: u64, wait_sequence: u64, consumed: u64,
        pending: Option<Pending>, waiting: Option<Waiting>, rows: [Row; 18], sequence_exhausted: bool,
    }
    impl State {
        const fn new() -> Self { Self { epoch: 0, enabled: false, sequence: 0, wait_sequence: 0, consumed: 0,
            pending: None, waiting: None, rows: [Row::new(); 18], sequence_exhausted: false } }
        fn enter(&mut self, epoch: u64, enabled: bool) -> bool {
            if epoch == 0 { return false }
            if self.epoch != epoch { *self = Self::new(); self.epoch = epoch; self.enabled = enabled; }
            self.enabled
        }
        fn begin_ready(&mut self, kind: Kind, now: Instant) -> Option<u64> {
            if self.pending.is_some() { self.rows[13].add(0); return None }
            let Some(sequence) = self.sequence.checked_add(1) else { self.sequence_exhausted = true; return None };
            self.sequence = sequence;
            if let Some(waiting) = &mut self.waiting {
                if !waiting.prepared_at_entry && waiting.first_prepared_during.is_none() { waiting.first_prepared_during = Some(now); }
            }
            self.pending = Some(Pending { sequence, kind, start: now }); self.rows[0].add(0); Some(sequence)
        }
        fn begin_wait(&mut self, now: Instant) -> Option<u64> {
            if self.waiting.is_some() { self.rows[13].add(0); return None }
            let Some(sequence) = self.wait_sequence.checked_add(1) else { self.sequence_exhausted = true; return None };
            self.wait_sequence = sequence;
            self.waiting = Some(Waiting { sequence, start: now, prepared_at_entry: self.pending.is_some(), first_prepared_during: None }); Some(sequence)
        }
        fn end_wait(&mut self, sequence: u64, now: Instant) {
            if self.waiting.as_ref().is_none_or(|w| w.sequence != sequence) { return }
            let wait = self.waiting.take().unwrap();
            self.rows[if wait.prepared_at_entry { 1 } else { 2 }].add(ns(wait.start, now));
            if let Some(ready_at) = wait.first_prepared_during { self.rows[3].add(ns(ready_at, now)); }
        }
        fn receive(&mut self, kind: Kind, now: Instant) {
            let Some(pending) = &self.pending else { self.rows[7].add(0); return };
            if pending.kind != kind { self.rows[8].add(0); return }
            let pending = self.pending.take().unwrap(); self.consumed = pending.sequence; self.rows[6].add(ns(pending.start, now));
            crate::import_gate_diagnostics::consumed(self.epoch, pending.sequence, now);
        }
        fn gate(&mut self, safe: bool) {
            if self.pending.is_some() { self.rows[15].add(0); self.rows[if safe { 17 } else { 16 }].add(0); }
        }
        fn empty(&mut self) { self.rows[if self.pending.is_some() { 4 } else { 5 }].add(0); }
        fn end_ready(&mut self, sequence: u64, outcome: Option<bool>) {
            if self.pending.as_ref().is_some_and(|p| p.sequence == sequence) {
                self.pending = None;
                crate::import_gate_diagnostics::abandoned(self.epoch, sequence);
            }
            match outcome {
                Some(true) => self.rows[if self.consumed == sequence { 9 } else { 10 }].add(0),
                Some(false) => self.rows[11].add(0),
                None => self.rows[12].add(0),
            }
        }
    }
    static STATE: Mutex<State> = Mutex::new(State::new());
    fn flag(value: Option<&str>) -> bool { value == Some("1") }
    fn ns(start: Instant, end: Instant) -> u64 { u64::try_from(end.duration_since(start).as_nanos()).unwrap_or(u64::MAX) }
    fn current<R>(f: impl FnOnce(&mut State) -> R) -> Option<(u64, R)> {
        let epoch = crate::import_timing::current_fixture_epoch();
        if epoch == 0 { return None }
        let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
        if crate::import_timing::current_fixture_epoch() != epoch { return None }
        let enabled = if state.epoch == epoch { state.enabled } else { flag(std::env::var("LW_CATALOG_IMPORT_READINESS_OBSERVATION").ok().as_deref()) };
        if !state.enter(epoch, enabled) { return None }
        Some((epoch, f(&mut state)))
    }
    fn matching(epoch: u64, f: impl FnOnce(&mut State)) {
        if crate::import_timing::current_fixture_epoch() != epoch { return }
        let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
        if state.epoch == epoch && state.enabled && crate::import_timing::current_fixture_epoch() == epoch { f(&mut state) }
    }
    pub(crate) struct Ready { key: Option<(u64, u64)> }
    pub(crate) fn ready(kind: Kind) -> Ready {
        let key = current(|state| state.begin_ready(kind, Instant::now())).and_then(|(epoch, sequence)| sequence.map(|s| (epoch, s)));
        Ready { key }
    }
    impl Ready {
        pub(crate) fn finish(mut self, ok: bool) {
            if let Some((epoch, sequence)) = self.key.take() { matching(epoch, |state| state.end_ready(sequence, Some(ok))); }
        }
    }
    impl Drop for Ready {
        fn drop(&mut self) { if let Some((epoch, sequence)) = self.key.take() { matching(epoch, |state| state.end_ready(sequence, None)); } }
    }
    pub(crate) struct Wait { key: Option<(u64, u64)> }
    pub(crate) fn wait() -> Wait {
        let key = current(|state| state.begin_wait(Instant::now())).and_then(|(epoch, sequence)| sequence.map(|s| (epoch, s)));
        Wait { key }
    }
    impl Drop for Wait {
        fn drop(&mut self) { if let Some((epoch, sequence)) = self.key.take() { matching(epoch, |state| state.end_wait(sequence, Instant::now())); } }
    }
    pub(crate) fn poll<T>(call: impl FnOnce() -> Result<T, std::sync::mpsc::TryRecvError>, kind: impl FnOnce(&T) -> Kind) -> Result<T, std::sync::mpsc::TryRecvError> {
        let epoch = crate::import_timing::current_fixture_epoch();
        if epoch == 0 { return call() }
        let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
        let enabled = if state.epoch == epoch { state.enabled } else { flag(std::env::var("LW_CATALOG_IMPORT_READINESS_OBSERVATION").ok().as_deref()) };
        if crate::import_timing::current_fixture_epoch() != epoch || !state.enter(epoch, enabled) { drop(state); return call() }
        // This closure is the existing nonblocking try_recv only. Hold the
        // diagnostic lock until matching consumption is recorded, so send's
        // return cannot erase the observation before the receiver records it.
        observed_poll(&mut state, call, kind)
    }
    fn observed_poll<T>(state: &mut State, call: impl FnOnce() -> Result<T, std::sync::mpsc::TryRecvError>, kind: impl FnOnce(&T) -> Kind) -> Result<T, std::sync::mpsc::TryRecvError> {
        let result = call();
        match &result {
            Ok(event) => state.receive(kind(event), Instant::now()),
            Err(std::sync::mpsc::TryRecvError::Empty) => state.empty(),
            Err(std::sync::mpsc::TryRecvError::Disconnected) => state.rows[14].add(0),
        }
        result
    }
    pub(crate) fn gate(safe: bool) { current(|state| state.gate(safe)); }
    // Release this lock before any service predicate or diagnostic state lock.
    pub(crate) fn pending_sequence() -> Option<(u64, Option<u64>)> {
        current(|state| state.pending.as_ref().map(|pending| pending.sequence))
    }
    pub(crate) fn snapshot() -> Option<serde_json::Value> {
        current(|state| serde_json::json!({
            "schema":1,"scope":"fixture_only_finalized_event_handoff_observation_no_wakeup_change",
            "epoch":state.epoch,"sequence_exhausted":state.sequence_exhausted,
            "pending_finalized_event":state.pending.as_ref().map(|p| serde_json::json!({"sequence":p.sequence,"kind":KINDS[p.kind as usize]})),
            "actor_wait_active":state.waiting.is_some(),"bucket_upper_ns":LIMITS,
            "rows":ROWS.iter().zip(state.rows.iter()).map(|(name,row)| serde_json::json!({"name":name,"count":row.count,"sum_ns":row.sum,"max_ns":row.max,"buckets":row.buckets,"saturated":row.saturated})).collect::<Vec<_>>(),
            "limits":"Prepared Event is held before send. Internal std::mpsc enqueue/blocked state is NOT observable. Empty poll with pending does not establish internal registration or its timing; it preserves the announce/readiness ambiguity. Wait duration is caller walltime, not avoidable fraction or CPU. No source paths/events/unbounded logs."})).map(|(_, value)| value)
    }
    // Serialization-cap fixture only: exercise the real fixed State and real
    // snapshot writer. Saturated rows intentionally have maximum-width values;
    // this does not attest any real event counts or elapsed durations.
    #[cfg(test)]
    pub(crate) fn maximal_serialization_fixture() -> bool {
        current(|state| {
            for row in &mut state.rows {
                *row = Row { count: u64::MAX, sum: u64::MAX, max: u64::MAX,
                    buckets: [u64::MAX; 6], saturated: true };
            }
            state.sequence = u64::MAX; state.wait_sequence = u64::MAX;
            state.pending = Some(Pending { sequence: u64::MAX, kind: Kind::Finished, start: Instant::now() });
            state.waiting = Some(Waiting { sequence: u64::MAX, start: Instant::now(),
                prepared_at_entry: true, first_prepared_during: None });
            state.sequence_exhausted = true;
        }).is_some()
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        fn active() -> State { let mut s = State::new(); assert!(s.enter(1, true)); s }
        #[test] fn observation_flag_is_exact_and_default_off() {
            assert!(flag(Some("1"))); for value in [None,Some("0"),Some("true"),Some("01"),Some(" 1"),Some("1 ")] { assert!(!flag(value)); }
        }
        #[test] fn epoch_zero_cannot_enable_observation() {
            let mut s=State::new();assert!(!s.enter(0,true));assert_eq!(s.epoch,0);assert!(!s.enabled);
        }
        #[test] fn disabled_attempt_remains_disabled_for_its_epoch() {
            let mut s=State::new();assert!(!s.enter(1,false));assert!(!s.enter(1,true));assert!(s.enter(2,true));
        }
        #[test] fn real_zero_capacity_send_waits_for_actual_receive() {
            let (tx,rx)=std::sync::mpsc::sync_channel(0);let (entered,entry)=std::sync::mpsc::sync_channel(0);let (done,completion)=std::sync::mpsc::sync_channel(0);
            let state=std::sync::Arc::new(Mutex::new(active()));let worker_state=state.clone();
            let worker=std::thread::spawn(move || { let key=worker_state.lock().unwrap().begin_ready(Kind::Header,Instant::now()).unwrap();entered.send(()).unwrap();
                let result=tx.send(Kind::Header);worker_state.lock().unwrap().end_ready(key,Some(result.is_ok()));done.send(()).unwrap(); });
            entry.recv_timeout(std::time::Duration::from_secs(2)).unwrap();assert!(matches!(completion.try_recv(),Err(std::sync::mpsc::TryRecvError::Empty)));
            {let mut s=state.lock().unwrap();let event=rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();observed_poll(&mut s,||Ok(event),|event|*event).unwrap();}
            completion.recv_timeout(std::time::Duration::from_secs(2)).unwrap();worker.join().unwrap();
            let s=state.lock().unwrap();assert_eq!(s.rows[9].count,1);assert_eq!(s.rows[10].count,0);assert_eq!(s.rows[0].count,1);
        }
        #[test] fn real_receiver_drop_unblocks_sender_without_consumption_claim() {
            let (tx,rx)=std::sync::mpsc::sync_channel(0);let (entered,entry)=std::sync::mpsc::sync_channel(0);let (done,completion)=std::sync::mpsc::sync_channel(0);
            let state=std::sync::Arc::new(Mutex::new(active()));let worker_state=state.clone();
            let worker=std::thread::spawn(move || {let key=worker_state.lock().unwrap().begin_ready(Kind::End,Instant::now()).unwrap();entered.send(()).unwrap();
                let result=tx.send(Kind::End);worker_state.lock().unwrap().end_ready(key,Some(result.is_ok()));done.send(()).unwrap();});
            entry.recv_timeout(std::time::Duration::from_secs(2)).unwrap();drop(rx);completion.recv_timeout(std::time::Duration::from_secs(2)).unwrap();worker.join().unwrap();
            let s=state.lock().unwrap();assert_eq!(s.rows[11].count,1);assert_eq!(s.rows[6].count,0);assert!(s.pending.is_none());
        }
        #[test] fn same_nonblocking_poll_call_is_executed_exactly_once() {
            let mut s=active();let mut calls=0;s.begin_ready(Kind::Header,Instant::now()).unwrap();
            let result=observed_poll(&mut s,||{calls+=1;Err::<Kind,_>(std::sync::mpsc::TryRecvError::Empty)},|event|*event);
            assert!(matches!(result,Err(std::sync::mpsc::TryRecvError::Empty)));assert_eq!(calls,1);assert_eq!(s.rows[4].count,1);
        }
        #[test] fn same_poll_disconnection_does_not_mint_a_consumed_event() {
            let mut s=active();let result=observed_poll(&mut s,||Err::<Kind,_>(std::sync::mpsc::TryRecvError::Disconnected),|event|*event);
            assert!(matches!(result,Err(std::sync::mpsc::TryRecvError::Disconnected)));assert_eq!(s.rows[14].count,1);assert_eq!(s.rows[7].count,0);
        }
        #[test] fn canceled_prepared_during_wait_overlap_remains_observed() {
            let mut s=active();let wait=s.begin_wait(Instant::now()).unwrap();let key=s.begin_ready(Kind::Header,Instant::now()).unwrap();
            s.end_ready(key,Some(false));s.end_wait(wait,Instant::now());assert_eq!(s.rows[3].count,1);assert_eq!(s.rows[11].count,1);assert!(s.pending.is_none());
        }
        #[test] fn actual_safe_gate_value_is_counted_without_changing_decision() {
            let mut s=active();s.begin_ready(Kind::Header,Instant::now()).unwrap();s.gate(false);s.gate(true);
            assert_eq!(s.rows[15].count,2);assert_eq!(s.rows[16].count,1);assert_eq!(s.rows[17].count,1);assert_eq!(s.rows[6].count,0);
        }
        #[test] fn safe_gate_without_prepared_payload_does_not_mint_waiting_event() {
            let mut s=active();s.gate(false);s.gate(true);assert_eq!(s.rows[15].count,0);assert!(s.pending.is_none());
        }
        #[test] fn event_first_wait_observes_finalized_payload() {
            let mut s=active();let t=Instant::now();let ready=s.begin_ready(Kind::Header,t).unwrap();let wait=s.begin_wait(t).unwrap();
            s.end_wait(wait,Instant::now());s.receive(Kind::Header,Instant::now());s.end_ready(ready,Some(true));
            assert_eq!(s.rows[1].count,1);assert_eq!(s.rows[6].count,1);assert_eq!(s.rows[9].count,1);assert!(s.pending.is_none());
        }
        #[test] fn waiter_first_marks_overlap_without_claiming_enqueue() {
            let mut s=active();let t=Instant::now();let wait=s.begin_wait(t).unwrap();s.begin_ready(Kind::Header,Instant::now()).unwrap();
            s.end_wait(wait,Instant::now());assert_eq!(s.rows[2].count,1);assert_eq!(s.rows[3].count,1);assert_eq!(s.rows[1].count,0);
        }
        #[test] fn announce_before_registration_empty_is_explicit() {
            let mut s=active();s.begin_ready(Kind::Header,Instant::now()).unwrap();s.empty();assert_eq!(s.rows[4].count,1);assert_eq!(s.rows[6].count,0);
        }
        #[test] fn one_pending_bound_preserves_first_owner() {
            let mut s=active();let first=s.begin_ready(Kind::Header,Instant::now()).unwrap();assert!(s.begin_ready(Kind::Source,Instant::now()).is_none());
            assert_eq!(s.pending.as_ref().unwrap().sequence,first);assert_eq!(s.rows[13].count,1);
        }
        #[test] fn cancellation_error_clears_only_exact_pending_guard() {
            let mut s=active();let key=s.begin_ready(Kind::End,Instant::now()).unwrap();s.end_ready(key,Some(false));assert!(s.pending.is_none());assert_eq!(s.rows[11].count,1);
        }
        #[test] fn stale_guard_does_not_clear_new_pending_sequence() {
            let mut s=active();let old=s.begin_ready(Kind::Header,Instant::now()).unwrap();s.receive(Kind::Header,Instant::now());let new=s.begin_ready(Kind::Source,Instant::now()).unwrap();
            s.end_ready(old,Some(true));assert_eq!(s.pending.as_ref().unwrap().sequence,new);
        }
        #[test] fn new_attempt_discards_prior_observation_state() {
            let mut s=active();s.begin_ready(Kind::Header,Instant::now()).unwrap();assert!(s.enter(2,true));assert!(s.pending.is_none());assert_eq!(s.rows[0].count,0);
        }
        #[test] fn spurious_wait_without_event_stays_clear() {
            let mut s=active();let key=s.begin_wait(Instant::now()).unwrap();s.end_wait(key,Instant::now());s.empty();assert_eq!(s.rows[2].count,1);assert_eq!(s.rows[5].count,1);
        }
        #[test] fn kind_mismatch_never_mints_consumption() {
            let mut s=active();let key=s.begin_ready(Kind::Header,Instant::now()).unwrap();s.receive(Kind::End,Instant::now());assert_eq!(s.rows[8].count,1);assert_eq!(s.rows[6].count,0);
            s.end_ready(key,Some(true));assert_eq!(s.rows[10].count,1);
        }
        #[test] fn close_unwind_does_not_turn_pending_into_success() {
            let mut s=active();let key=s.begin_ready(Kind::Header,Instant::now()).unwrap();s.end_ready(key,None);assert!(s.pending.is_none());assert_eq!(s.rows[12].count,1);assert_eq!(s.rows[9].count,0);
        }
        #[test] fn sequence_exhaustion_is_not_wrapped_authority() {
            let mut s=active();s.sequence=u64::MAX;assert!(s.begin_ready(Kind::End,Instant::now()).is_none());assert!(s.sequence_exhausted);assert!(s.pending.is_none());
        }
        #[test] fn counts_and_histograms_are_bounded_and_coherent() {
            let mut row=Row::new();for n in [0,100_000,100_001,1_000_000,1_000_001,10_000_001,100_000_001,1_000_000_001] { row.add(n); }
            assert_eq!(row.count,8);assert_eq!(row.buckets.iter().sum::<u64>(),8);assert_eq!(row.buckets,[2,2,1,1,1,1]);assert!(!row.saturated);
        }
    }
}
#[cfg(feature = "import-timing-fixture")]
pub(crate) use enabled::*;

#[cfg(all(test, not(feature = "import-timing-fixture")))]
mod disabled_tests {
    #[test] fn defaultoff_observer_guards_are_zero_sized() {
        assert_eq!(std::mem::size_of::<super::Ready>(),0);
        assert_eq!(std::mem::size_of::<super::Wait>(),0);
        super::ready(super::Kind::Header).finish(true);drop(super::wait());super::gate(false);
        let mut calls=0;let result=super::poll(||{calls+=1;Err::<super::Kind,_>(std::sync::mpsc::TryRecvError::Empty)},|event|*event);
        assert!(matches!(result,Err(std::sync::mpsc::TryRecvError::Empty)));assert_eq!(calls,1);
    }
}
