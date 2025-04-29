/// Module: raffle
module raffle::raffle {

    use iota::balance::{Self, Balance};
    use iota::coin::{Coin};
    use iota::clock::{Clock};
    use iota::random::{Self, Random};
    use iota::table::{Self, Table};

    // Errors
    #[error]
    const ERaffleAlreadyResolved: vector<u8> = 
        b"Can't resolve raffle that is already resolved.";
    #[error]
    const ERaffleNotResolvableYet: vector<u8> = 
        b"Raffle can't be resolved yet, because it still open.";
    #[error]
    const ERaffleNotResolved: vector<u8> = 
        b"Can't claim raffle prize, because it's not resolved yet.";
    #[error]
    const ETicketDidNotWin: vector<u8> = 
        b"Can't claim raffle prize with this ticket, since it did not win.";
    #[error]
    const EInsufficientInitialLiquidity: vector<u8> = 
        b"Not enough initial liquidity. Minimum amount required to prevent spam.";
    #[error]
    const EIncorrectTicketPayment: vector<u8> =
        b"Incorrect amount as ticket payment.";
    #[error]
    const EGiveAwayDoesNotSupportTicketSale: vector<u8> = 
        b"Can't buy tickets for a giveaway.";
    #[error]
    const ERaffleNotGiveaway: vector<u8> = 
        b"Can't enter into giveaway since raffle is not a giveaway.";
    #[error]
    const ENotGiveawayCreator: vector<u8> = 
        b"Caller is not creator of the giveaway.";

    // Constants
    // 1 bln tokens, for IOTA this is exactly 1 IOTA
    const DEFAULT_MIN_LIQUIDITY: u64 = 1_000_000_000;

    public struct RaffleAppState has key {
        id: UID,
        raffles: vector<ID>,
        raffles_created_count: u64,
        min_initial_liquidity: u64,
    }

    public struct AdminCap has key {
        id: UID
    }

    /// A raffle. Token `T` will be what is used to buy tickets for that raffle.
    public struct Raffle<phantom T> has key, store {
        id: UID,
        creator: address,
        raffle_num: u64,
        ticket_price: u64,
        redemption_timestamp_ms: u64,
        prize_money: Balance<T>,
        sold_tickets: vector<ID>,
        winning_ticket: Option<ID>, // set when the raffle is resolved
        is_giveaway: bool,
        url: vector<u8>,
    }

    /// A struct representing a ticket in a specific raffle.
    public struct RaffleTicket has key, store{
        id: UID
    }

    fun init(ctx: &mut TxContext) {
        // Create and share RaffleAppState
        let state = RaffleAppState { 
            id: object::new(ctx),
            raffles: vector[],
            raffles_created_count: 0,
            min_initial_liquidity: DEFAULT_MIN_LIQUIDITY,
        };

        transfer::share_object(state);

        // Create AdminCap and send to publisher
        let cap = AdminCap {
            id: object::new(ctx)
        };
        transfer::transfer(cap, ctx.sender());
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    public fun set_min_initial_liquidity(_: &AdminCap, state: &mut RaffleAppState, new_value: u64) {
        state.min_initial_liquidity = new_value;
    }

    /// Create a raffle
    entry fun create_raffle<T>(state: &mut RaffleAppState, initial_liquidity: Coin<T>, ticket_price: u64, duration_s: u64, is_giveaway: bool, url: vector<u8>, clock: &Clock, ctx: &mut TxContext) {

        assert!(initial_liquidity.value() >= state.min_initial_liquidity, EInsufficientInitialLiquidity);

        let redemption_timestamp_ms = clock.timestamp_ms() + 1000 * duration_s;
        let raffle_num = state.raffles_created_count + 1;
        let raffle = Raffle<T> {
            id: object::new(ctx),
            raffle_num,
            creator: ctx.sender(),
            ticket_price,
            redemption_timestamp_ms,
            prize_money: initial_liquidity.into_balance(),
            sold_tickets: vector[],
            winning_ticket: option::none(),
            is_giveaway,
            url,
        };
        state.raffles.push_back(raffle.id.to_inner());
        state.raffles_created_count = raffle_num;
        transfer::public_share_object(raffle);
    }

    public fun is_resolved<T>(raffle: &Raffle<T>): bool {
        raffle.winning_ticket.is_some()
    }

    public fun buy_ticket<T>(raffle: &mut Raffle<T>, payment_coin: Coin<T>, ctx: &mut TxContext): RaffleTicket {
        assert!(!raffle.is_giveaway, EGiveAwayDoesNotSupportTicketSale);
        assert!(!raffle.is_resolved(), ERaffleAlreadyResolved);
        assert!(payment_coin.value() == raffle.ticket_price, EIncorrectTicketPayment);

        // Add payment to the prize money
        raffle.prize_money.join(payment_coin.into_balance());
        
        // Create and transfer ticket
        let ticket_id = object::new(ctx);
        raffle.sold_tickets.push_back(ticket_id.to_inner());
        let ticket = RaffleTicket { id: ticket_id };
        ticket
    }

    public fun enter_into_giveaway<T>(raffle: &mut Raffle<T>, who: address, ctx: &mut TxContext) {
        assert!(raffle.is_giveaway, ERaffleNotGiveaway);
        assert!(raffle.creator == ctx.sender(), ENotGiveawayCreator);

        let ticket_id = object::new(ctx);
        raffle.sold_tickets.push_back(ticket_id.to_inner());
        let ticket = RaffleTicket { id: ticket_id };
        transfer::transfer(ticket, who);
    }

    /// Resolve the raffle (decide who wins)
    entry fun resolve<T>(raffle: &mut Raffle<T>, clock: &Clock, r: &Random, ctx: &mut TxContext) {
        // Can't resolve twice
        assert!(!raffle.is_resolved(), ERaffleAlreadyResolved);

        // Make sure that the raffle is ready to be resolved
        let current_timestamp_ms = clock.timestamp_ms();
        assert!(current_timestamp_ms >= raffle.redemption_timestamp_ms, ERaffleNotResolvableYet);

        // Pick a winner at random
        let tickets_sold = raffle.sold_tickets.length();
        let winner_idx = random::new_generator(r, ctx).generate_u64_in_range(0, tickets_sold - 1);
        raffle.winning_ticket = option::some(raffle.sold_tickets[winner_idx]);
    }

    /// Claim the prize money using the winning RaffleTicket
    public fun claim_prize_money<T>(raffle: &mut Raffle<T>, ticket: RaffleTicket, ctx: &mut TxContext): Coin<T> {
        assert!(raffle.is_resolved(), ERaffleNotResolved);

        let RaffleTicket { id: winning_ticket_id } = ticket;
        assert!(raffle.winning_ticket == option::some(*winning_ticket_id.as_inner()),
            ETicketDidNotWin
        );

        // Delete ticket
        object::delete(winning_ticket_id);

        // Send full prize_money balance to winner
        let prize_coin = raffle.prize_money.withdraw_all().into_coin(ctx);
        prize_coin
    }
}
