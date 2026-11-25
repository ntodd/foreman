// The life of one environment's attachment uploads in the control plane:
// opening one against the pending cap, chunks arriving in order, the one
// request that completes a file sending it to GitHub, and Housekeeping
// pruning what was abandoned. Requests overlap (a box relays four at once
// for a VM), the caller's access comes and goes, and GitHub takes the
// file, refuses it, or never answers.
//
//   quint run attachments.qnt --invariant=allInvariants --max-samples=30000 --max-steps=40
//
// Code it follows (apps/foreman):
//   lib/foreman/attachments.ex    start, open, append, upload (the lookup), store, write,
//                                 finish, assemble, deliver, writer, prune
//   lib/foreman/jobs/housekeeping.ex    Attachments.prune
//
// Modelling choices:
//   - One environment. A file is one or two chunks, and the cap is counted
//     in chunks.
//   - A request is several steps, each a statement or a transaction, and
//     any other request's step can come between two of them.
//   - Time is in coarse steps (STALE of them is the ten minutes an upload
//     may sit). A request finishes within a step: the clock only moves
//     when none is in flight.
//   - A chunk's bytes aren't modelled, only how many chunks are stored.
//
// The FIX_* switches are what review found missing from the first version,
// on as in the code. Each one off reproduces what it fixed.
module attachments {
  // ------------------------------------------------------------------ parameters
  pure val N_UPLOADS = 3
  pure val MAX_REQS = 7           // requests in a run
  pure val CONCURRENT = 3         // in flight at once
  pure val CAP = 3                // what one environment's open uploads may add up to
  pure val STALE = 2
  pure val MAX_TIME = 5
  pure val MAX_FLIPS = 3          // times the caller's access changes

  // open/4 locks the environment's row, so counting what it holds and
  // adding to it is one step. Without it two requests count the same room.
  pure val FIX_LOCK = true
  // There is one way to finish an upload: be the request whose chunk
  // completed it. Without it a completed upload also took an empty chunk
  // as "try again", from any number of requests at once.
  pure val FIX_SINGLE_FINISH = true
  // assemble/1 sends nothing unless every byte that was counted is there.
  pure val FIX_LENGTH = true
  // finish/2 deletes the upload whatever happened, a raise included.
  // Without it only a file GitHub took was deleted.
  pure val FIX_ALWAYS_DROP = true
  // upload/3 refuses an upload that has sat for STALE, pruned yet or not.
  pure val FIX_IDLE = true
  // upload/3 asks, for every chunk, whether the environment is still the
  // caller's to reach (its box, its repository).
  pure val FIX_ACCESS_CHUNK = true
  // writer/3: the person acting can write to the repository themselves.
  pure val FIX_WRITER = true

  pure val UPLOADS = 0.to(N_UPLOADS - 1)
  pure val REQS = 0.to(MAX_REQS - 1)

  // ------------------------------------------------------------------ types
  type Up = { size: int, received: int, updatedAt: int }
  type Outcome = Took | Refused | NoAnswer
  // Where a request has got to. Each holds what the request read earlier,
  // which is what it acts on however the rows have changed since.
  type Req =
    | Counted({ size: int, seen: int })                // start: counted, about to insert
    | Looked({ up: int, offset: int, stale: bool, unreachable: bool })  // append: found its upload
    | ToCheck({ up: int, size: int })                  // finish: about to reauthorize
    | ToAssemble({ up: int, size: int, writer: bool }) // finish: about to read the chunks
    | ToPost({ up: int, size: int, body: int, writer: bool })  // finish: about to send

  type State = {
    now: int,
    uploads: int -> Up,               // attachment_uploads
    chunks: int -> int,               // attachment_chunks, counted per upload
    nextUp: int,
    reqs: int -> Req,
    nextReq: int,
    // the caller
    reachable: bool,                  // the environment is theirs to reach
    writer: bool,                     // GitHub lets them push to the repository
    flips: int,
    // ghosts
    posts: int -> int,                // times each upload's file went to GitHub
    shortSent: bool,                  // a file went with fewer chunks than its size
    revived: bool,                    // a chunk landed on an upload that had sat too long
    wroteAfterLoss: bool,             // a chunk was taken for an environment out of reach
    sentForNonWriter: bool,           // a file went for someone who couldn't write
    finished: Set[int],               // uploads whose finish has run to its end
    // witnesses: the paths the properties are about do happen
    everPosted: bool,
    everPruned: bool,
    everOverCap: bool,                // a start was refused for want of room
    everNoAnswer: bool,
    everShortCaught: bool,            // assemble found chunks missing
  }

  var st: State

  // ------------------------------------------------------------------ helpers
  pure def without(m: int -> a, k: int): int -> a = m.keys().exclude(Set(k)).mapBy(x => m.get(x))
  pure def has(m: int -> a, k: int): bool = m.keys().contains(k)

  pure def pending(s: State): int = s.uploads.keys().fold(0, (n, k) => n + s.uploads.get(k).size)
  pure def idle(s: State, k: int): bool = s.now - s.uploads.get(k).updatedAt >= STALE
  pure def stored(s: State, k: int): int = if (s.chunks.has(k)) s.chunks.get(k) else 0

  // Deleting an upload takes its chunks with it (the foreign key cascades).
  pure def drop(s: State, k: int): State =
    { ...s, uploads: without(s.uploads, k), chunks: without(s.chunks, k) }

  pure def done(s: State, r: int): State = { ...s, reqs: without(s.reqs, r) }

  // A finish that ends without the file having gone, or after it has.
  pure def finish(s: State, r: int, k: int, took: bool): State = {
    val kept = if (took or FIX_ALWAYS_DROP) drop(s, k) else s
    done({ ...kept, finished: kept.finished.union(Set(k)) }, r)
  }

  pure def insert(s: State, n: int): State = {
    ...s,
    uploads: s.uploads.put(s.nextUp, { size: n, received: 0, updatedAt: s.now }),
    nextUp: s.nextUp + 1,
  }

  // ------------------------------------------------------------------ init
  action init = st' = {
    now: 0,
    uploads: Map(),
    chunks: Map(),
    nextUp: 0,
    reqs: Map(),
    nextReq: 0,
    reachable: true,
    writer: true,
    flips: 0,
    posts: Map(),
    shortSent: false,
    revived: false,
    wroteAfterLoss: false,
    sentForNonWriter: false,
    finished: Set(),
    everPosted: false,
    everPruned: false,
    everOverCap: false,
    everNoAnswer: false,
    everShortCaught: false,
  }

  // ------------------------------------------------------------------ opening

  // start/3 as far as counting: the environment is the caller's, they can
  // write to its repository, and what it holds is counted (its abandoned
  // uploads dropped first). With the lock the insert is in the same step.
  action beginStart = {
    nondet n = Set(1, 2).oneOf()
    all {
      st.nextUp < N_UPLOADS,
      st.nextReq < MAX_REQS,
      st.reqs.keys().size() < CONCURRENT,
      st.reachable,
      st.writer or not(FIX_WRITER),
      val swept = st.uploads.keys().filter(k => idle(st, k)).fold(st, (s, k) => drop(s, k))
      val seen = pending(swept)
      val s1 = { ...swept, nextReq: swept.nextReq + 1 }
      st' = if (not(FIX_LOCK))
              { ...s1, reqs: s1.reqs.put(st.nextReq, Counted({ size: n, seen: seen })) }
            else if (seen + n <= CAP) insert(s1, n)
            else { ...s1, everOverCap: true },
    }
  }

  // open/4 without the lock: insert on the strength of what was counted.
  action insertCounted = {
    nondet r = REQS.oneOf()
    all {
      st.reqs.has(r),
      match st.reqs.get(r) { | Counted(_) => true | _ => false },
      val c = match st.reqs.get(r) { | Counted(x) => x | _ => { size: 0, seen: 0 } }
      val s1 = done(st, r)
      st' = if (c.seen + c.size <= CAP) insert(s1, c.size) else { ...s1, everOverCap: true },
    }
  }

  // ------------------------------------------------------------------ chunks

  // append/4 as far as upload/3: the request finds its upload. A client
  // sends any offset it likes. One at the file's size is the empty chunk
  // that used to mean "try sending it again".
  action beginAppend = {
    nondet k = UPLOADS.oneOf()
    nondet offset = Set(0, 1, 2).oneOf()
    all {
      st.nextReq < MAX_REQS,
      st.reqs.keys().size() < CONCURRENT,
      st.uploads.has(k),
      st.reachable or not(FIX_ACCESS_CHUNK),
      not(idle(st, k)) or not(FIX_IDLE),
      val up = st.uploads.get(k)
      val retry = offset == up.size
      all {
        offset <= up.size,
        retry implies (not(FIX_SINGLE_FINISH) and up.received == up.size),
        val req = if (retry) ToCheck({ up: k, size: up.size })
                  else Looked({ up: k, offset: offset, stale: idle(st, k), unreachable: not(st.reachable) })
        st' = { ...st, nextReq: st.nextReq + 1, reqs: st.reqs.put(st.nextReq, req) },
      },
    }
  }

  // write/4: one transaction. The upload moves on only if it stands where
  // this chunk starts, and the chunk is stored with it. The request whose
  // chunk completes the file goes on to finish it.
  action write = {
    nondet r = REQS.oneOf()
    all {
      st.reqs.has(r),
      match st.reqs.get(r) { | Looked(_) => true | _ => false },
      val l = match st.reqs.get(r) {
        | Looked(x) => x
        | _ => { up: 0, offset: 0, stale: false, unreachable: false }
      }
      val k = l.up
      val lands = if (st.uploads.has(k)) st.uploads.get(k).received == l.offset else false
      st' = if (not(lands)) done(st, r)
            else {
              val up = st.uploads.get(k)
              val received = up.received + 1
              val s1 = { ...st,
                uploads: st.uploads.set(k, { ...up, received: received, updatedAt: st.now }),
                chunks: st.chunks.put(k, stored(st, k) + 1),
                revived: st.revived or l.stale,
                wroteAfterLoss: st.wroteAfterLoss or l.unreachable }
              if (received == up.size)
                { ...s1, reqs: s1.reqs.set(r, ToCheck({ up: k, size: up.size })) }
              else done(s1, r)
            },
    }
  }

  // ------------------------------------------------------------------ finishing

  // finish/2 as far as its checks: the environment is still the caller's,
  // and they can write to the repository. Either can fail, and reading the
  // environment can raise (GitHub couldn't be asked).
  action check = {
    nondet r = REQS.oneOf()
    nondet raised = Set(true, false).oneOf()
    all {
      st.reqs.has(r),
      match st.reqs.get(r) { | ToCheck(_) => true | _ => false },
      val c = match st.reqs.get(r) { | ToCheck(x) => x | _ => { up: 0, size: 0 } }
      val ok = st.reachable and (st.writer or not(FIX_WRITER)) and not(raised)
      st' = if (ok)
              { ...st, reqs: st.reqs.set(r, ToAssemble({ up: c.up, size: c.size, writer: st.writer })) }
            else finish(st, r, c.up, false),
    }
  }

  // assemble/1: read the chunks that are there now.
  action assemble = {
    nondet r = REQS.oneOf()
    all {
      st.reqs.has(r),
      match st.reqs.get(r) { | ToAssemble(_) => true | _ => false },
      val a = match st.reqs.get(r) { | ToAssemble(x) => x | _ => { up: 0, size: 0, writer: false } }
      val body = stored(st, a.up)
      st' = if (FIX_LENGTH and body != a.size)
              { ...finish(st, r, a.up, false), everShortCaught: true }
            else
              { ...st, reqs: st.reqs.set(r,
                  ToPost({ up: a.up, size: a.size, body: body, writer: a.writer })) },
    }
  }

  // deliver/5: the file goes to GitHub, once, and GitHub takes it, refuses
  // it, or gives no answer (in which case it may have it).
  action post = {
    nondet r = REQS.oneOf()
    nondet out = Set(Took, Refused, NoAnswer).oneOf()
    all {
      st.reqs.has(r),
      match st.reqs.get(r) { | ToPost(_) => true | _ => false },
      val p = match st.reqs.get(r) {
        | ToPost(x) => x
        | _ => { up: 0, size: 0, body: 0, writer: false }
      }
      val sent = { ...st,
        posts: st.posts.put(p.up, (if (st.posts.has(p.up)) st.posts.get(p.up) else 0) + 1),
        shortSent: st.shortSent or p.body != p.size,
        sentForNonWriter: st.sentForNonWriter or not(p.writer),
        everPosted: true,
        everNoAnswer: st.everNoAnswer or out == NoAnswer }
      st' = finish(sent, r, p.up, out == Took),
    }
  }

  // ------------------------------------------------------------------ the rest

  // Attachments.prune: Housekeeping drops what nothing has been sent to.
  action prune = {
    nondet k = UPLOADS.oneOf()
    all {
      st.uploads.has(k),
      idle(st, k),
      st' = { ...drop(st, k), everPruned: true },
    }
  }

  // The box stops being shared, or is shared again; the repository leaves
  // Foreman or comes back.
  action reach = all {
    st.flips < MAX_FLIPS,
    st' = { ...st, reachable: not(st.reachable), flips: st.flips + 1 },
  }

  // The person's role on the repository changes on GitHub.
  action role = all {
    st.flips < MAX_FLIPS,
    st' = { ...st, writer: not(st.writer), flips: st.flips + 1 },
  }

  // Coarse steps: a request is over within one.
  action tick = all {
    st.now < MAX_TIME,
    st.reqs.keys() == Set(),
    st' = { ...st, now: st.now + 1 },
  }

  action step = any {
    beginStart, insertCounted, beginAppend, write,
    check, assemble, post,
    prune, reach, role, tick,
  }

  // ------------------------------------------------------------------ properties

  // An upload can't be taken back, so a file goes to GitHub at most once.
  // (Sent and unanswered, it is sent again only as a new upload.)
  val sentOnce = st.posts.keys().forall(k => st.posts.get(k) <= 1)

  // And never short of the size it was opened with: that would be a broken
  // image, or an empty one, in someone's pull request.
  val neverShort = not(st.shortSent)

  // One environment's open uploads never add up to more than the cap.
  val withinCap = pending(st) <= CAP

  // Once an upload's finish has run, whatever came of it, nothing is left
  // of it to count against the environment.
  val finishedIsGone = st.finished.forall(k => not(st.uploads.has(k)))

  // An upload that has sat for STALE takes nothing more, whether or not
  // Housekeeping has been by.
  val noRevival = not(st.revived)

  // No chunk is taken for an environment that was out of the caller's
  // reach when the request found its upload. (One found in reach can still
  // land after access goes. Nothing is sent on the strength of it: finish
  // asks again.)
  val nothingTakenOutOfReach = not(st.wroteAfterLoss)

  // A file is sent only for someone who could write to the repository when
  // finish asked. (GitHub can change its mind before the file arrives.
  // Largely by construction: the check and the ghost read the same thing.)
  val writersOnly = not(st.sentForNonWriter)

  // Witnesses, expected to be violated: each says a path the properties
  // are about is reachable, so they don't pass for want of it.
  val noPosts = not(st.everPosted)
  val noPrunes = not(st.everPruned)
  val noCapRefusals = not(st.everOverCap)
  val noLostAnswers = not(st.everNoAnswer)
  val noShortCaught = not(st.everShortCaught)

  val allInvariants = and {
    sentOnce,
    neverShort,
    withinCap,
    finishedIsGone,
    noRevival,
    nothingTakenOutOfReach,
    writersOnly,
  }
}
