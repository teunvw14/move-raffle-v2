#[test_only]
module raffle::raffle_tests {
    use raffle::raffle::{Self, Raffle, RaffleAppState, RaffleTicket};
    use iota::test_scenario::{Self, Scenario};
    use iota::test_utils::assert_eq;
    use iota::coin::{Self, Coin};
    use iota::iota::IOTA;
    use iota::clock::{Self, Clock};
    use iota::random::{Self, Random};

    const ENotImplemented: u64 = 0;

    #[test]
    fun test_raffle() {
        let system_address = @0x0;
        let mut ts = test_scenario::begin(system_address);
        random::create_for_testing(ts.ctx());
        ts.next_tx(system_address);
        let mut random = ts.take_shared<Random>();
        random.update_randomness_state_for_testing(0, b"bla", ts.ctx());

        let admin_address = @0x1111;
        ts.next_tx(admin_address);
        let mut clock = clock::create_for_testing(ts.ctx());
        ts.next_tx(admin_address);
        raffle::init_for_testing(ts.ctx());
        ts.next_tx(admin_address);

        let mut state = ts.take_shared<RaffleAppState>();

        // create raffle
        let initial_liquidity: Coin<IOTA> = iota::coin::mint_for_testing<IOTA>(5_000_000_000, ts.ctx());

        raffle::create_raffle(
            &mut state, 
            initial_liquidity,
            100_000_000,
            10,
            &clock,
            ts.ctx(),
        );
        ts.next_tx(admin_address);

        let ticket_payment = iota::coin::mint_for_testing<IOTA>(100_000_000, ts.ctx());
        let ticket_payment_2 = iota::coin::mint_for_testing<IOTA>(100_000_000, ts.ctx());
        ts.next_tx(admin_address);
        let mut raffle = ts.take_shared<Raffle<IOTA>>();
        let ticket = raffle.buy_ticket(ticket_payment, ts.ctx());
        ts.next_tx(admin_address);

        let ticket_2 = raffle.buy_ticket(ticket_payment_2, ts.ctx());
        ts.next_tx(admin_address);

        // Increment 50 seconds
        clock.increment_for_testing(10_000);
        ts.next_tx(admin_address);
    
        raffle.resolve(&clock, &random, ts.ctx());
        ts.next_tx(admin_address);

        let payout = raffle.claim_prize_money(ticket, ts.ctx());
        assert_eq(payout.value(), 5_200_000_000);
        ts.next_tx(admin_address);
        transfer::public_transfer(payout, admin_address);
        ts.next_tx(admin_address);

        test_scenario::return_shared(state);
        test_scenario::return_shared(raffle);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clock);
        transfer::public_transfer(ticket_2, admin_address);
        ts.end();
    }

    // #[test, expected_failure(abort_code = ::raffle::raffle_tests::ENotImplemented)]
    // fun test_raffle_fail() {
    //     abort ENotImplemented
    // }
}
