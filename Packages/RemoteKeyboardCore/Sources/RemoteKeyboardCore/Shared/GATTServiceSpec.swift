public enum GATTServiceSpec {
    public static let serviceUUID = "2A6F212A-3B7A-4293-87B4-FAD198077EFB"
    /// Write with response.
    public static let inputUUID = "92A59A91-80A0-4743-8E65-F297A9B05104"
    /// Notify.
    public static let ackUUID = "6AEB18CE-45D1-47B8-9F18-96939C182189"
    /// Read + notify.
    public static let statusUUID = "99FA0347-3B23-498D-A0F0-1EE6B0AAA76E"
}

extension GATTServiceSpec {
    /// iPhone keyboard is the peripheral; the Mac Receiver is the central.
    public enum Link {
        public static let serviceUUID = "706AA642-68A3-41FA-889D-24E30709B0D0"
        /// Notify.
        public static let eventUUID = "C7FC0313-53E7-4DCD-B75F-2AE66FE9C586"
        /// Write with response.
        public static let controlUUID = "320468E2-53B6-4B6A-88EC-AE2752415818"
        /// What the pairing screen of the iPhone advertises while a pairing window is open. Hosts scan for it only while their
        /// own pairing window is open (docs/protocol/v4.md §1.2). The GATT database does not change; only the advert does.
        public static let pairingAdvertUUID = "6BA36ECB-1BF9-49C1-B98D-37402247F356"
    }
}
