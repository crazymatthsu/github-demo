package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class PushRetryTest {
    private val sleeps = mutableListOf<Long>()
    private val retries = mutableListOf<Pair<Int, Int>>()

    private fun run(attempts: Int, backoff: Long, attempt: (Int) -> Int) =
        PushRetry.run(attempts, backoff, { sleeps += it }, { n, exit -> retries += n to exit }, attempt)

    @Test
    fun `a push that succeeds at once neither sleeps nor retries`() {
        assertEquals(PushRetry.Outcome(0, 1), run(3, 100) { 0 })
        assertEquals(emptyList<Long>(), sleeps)
        assertEquals(emptyList<Pair<Int, Int>>(), retries)
    }

    @Test
    fun `transient failures are retried with a growing backoff until the push succeeds`() {
        var calls = 0
        assertEquals(PushRetry.Outcome(0, 3), run(3, 100) { calls++; if (calls < 3) 1 else 0 })
        assertEquals(listOf(100L, 200L), sleeps)
        assertEquals(listOf(1 to 1, 2 to 1), retries)
    }

    @Test
    fun `the last attempt's exit code is reported and nothing sleeps after it`() {
        assertEquals(PushRetry.Outcome(7, 2), run(2, 50) { 7 })
        assertEquals(listOf(50L), sleeps)
        assertEquals(listOf(1 to 7), retries)
    }

    @Test
    fun `the attempt number is passed to each attempt`() {
        val seen = mutableListOf<Int>()
        run(3, 1) { n -> seen += n; 1 }
        assertEquals(listOf(1, 2, 3), seen)
    }

    @Test
    fun `fewer than one attempt is rejected`() {
        assertThrows(IllegalArgumentException::class.java) { run(0, 1) { 0 } }
    }
}
