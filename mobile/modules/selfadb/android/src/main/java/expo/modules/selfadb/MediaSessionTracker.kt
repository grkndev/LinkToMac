package expo.modules.selfadb

/**
 * Which media session the phone follows, and the rule for WHEN it looks again.
 *
 * The bug it replaces: [MediaMirror] used to choose a session only when the platform's session LIST changed, and followed only a session that
 * already had a title. Many players activate their session first and write the title a moment later, so at the instant of the list change
 * nothing qualified, nothing was followed (no callback registered anywhere), and the later title raised no event for us: the Mac's card stayed
 * empty until "Mirror media" was switched off and on. Likewise, two sessions that were both already listed (one paused, one just started)
 * never triggered a new choice, so the Mac kept showing the paused one.
 *
 * So: **every** listed session is watched (a callback registered on it, title or not), and [reevaluate] re-reads the candidates whenever any
 * watched session reports a change. Plain Kotlin and generic in the controller type [C], so a JVM test drives it with fakes; the choice itself is
 * [MediaState.pickCurrent] (unchanged, already tested). Single-threaded by contract: [MediaMirror] calls it only on its own handler thread.
 *
 * @param tokenOf identity of a session across list updates (the platform hands out new controller objects for the same session)
 * @param candidateOf whether the session plays and has a title; may throw (no access): such a session simply has nothing to show
 * @param register start receiving that session's callbacks; may throw: the session is then not watched and is retried on the next [update]
 * @param unregister stop receiving them
 * @param onError told about a session [register] failed on (the caller logs a class name, never anything about the session)
 */
class MediaSessionTracker<C : Any>(
  private val tokenOf: (C) -> Any,
  private val candidateOf: (C) -> MediaState.Candidate,
  private val register: (C) -> Unit,
  private val unregister: (C) -> Unit,
  private val onError: (C, Exception) -> Unit = { _, _ -> },
) {
  /** The watched sessions in the platform's priority order (most recently active first), by token. */
  private var watched: List<Pair<Any, C>> = emptyList()

  /** The session to mirror, or null when none has anything to show. */
  var current: C? = null
    private set

  /**
   * The platform's list changed: watch the new sessions, release the ones that went away, choose again.
   * @return whether the chosen session changed
   */
  fun update(list: List<C>): Boolean {
    val before = watched.associate { it.first to it.second }
    val next = ArrayList<Pair<Any, C>>(list.size)
    val seen = HashSet<Any>()
    for (c in list) {
      val token = tokenOf(c)
      if (!seen.add(token)) continue // the same session listed twice
      val existing = before[token]
      if (existing != null) {
        next += token to existing // already registered on this controller object: keep it
      } else {
        try {
          register(c)
          next += token to c
        } catch (e: Exception) {
          onError(c, e) // not watched; retried on the next update
        }
      }
    }
    for ((token, c) in watched) if (token !in seen) unregister(c)
    watched = next
    return choose()
  }

  /**
   * A watched session reported a change (title, playback state, …): choose again among the sessions already watched.
   * @return whether the chosen session changed
   */
  fun reevaluate(): Boolean = choose()

  /** Release everything (the mirror stops). Safe to call twice; the tracker can be used again afterwards. */
  fun clear() {
    for ((_, c) in watched) unregister(c)
    watched = emptyList()
    current = null
  }

  private fun choose(): Boolean {
    val candidates = watched.map { (_, c) ->
      try { candidateOf(c) } catch (_: Exception) { MediaState.Candidate(playing = false, hasMetadata = false) }
    }
    val picked = MediaState.pickCurrent(candidates)?.let { watched[it].second }
    val changed = current?.let { tokenOf(it) } != picked?.let { tokenOf(it) }
    current = picked
    return changed
  }
}
