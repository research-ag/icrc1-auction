module {
  public let LOYALTY_REWARD = {
    WALLET_OPERATION = 10;
    ORDER_MODIFICATION = 1;
    ORDER_EXECUTION = 10;
    ORDER_VOLUME_DIVISOR = 100_000;
  };

  // how much quote tokens should be locked on user when they place a dark (encrypted) order book
  public let DARK_ORDER_BOOK_LOCK_AMOUNT = 1_000_000;
};
