// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Kiosk 是构建安全、去中心化和无需信任的交易体验的原始工具。它允许存储和交易任何类型的资产，只要这些资产的创建者为它们实现“TransferPolicy”。
///
/// ### 原则和理念:
///
/// - Kiosk 提供“真正所有权”的保证;- 就像单一所有者对象一样，存储在 Kiosk 中的资产只能由 Kiosk 所有者管理。 只有所有者才能对自助服务终端中的资产进行“place(放置)”、“take(获取)”、“list(列出)”或执行任何其他操作。
///
/// - Kiosk 的目标是成为通用的 - 允许一小部分默认行为，并且不对资产的交易方式施加任何限制。唯一的默认方案是“list”+“purchase”流程;任何其他交易逻辑都可以使用“list_with_purchase_cap”（和匹配的“purchase_with_cap”）流程在顶部实现。
///
/// - 对于与第三方发生的每笔交易，都会创建一个“TransferRequest”——这样创作者就可以完全控制交易经过。
///
/// ### Kiosk中的资产状态:
///
/// - `placed` -  资产被“放置”到Kiosk中，并且可以由Kiosk所有者使用“take”取出;它可以通过“borrow_mut”和“borrow_val”函数自由交易和修改。
///
/// - `locked` -与“placed”类似，不同之处在于“take”被禁用，将资产移出自助服务终端的唯一方法是使用“list”列出它或“list_with_purchase_cap”，从而执行交易（发出“TransferRequest”）。检查“lock”功能可确保“TransferPolicy”存在，以免将物品永远锁定在“Kiosk”中。
///
/// - `listed` - 使用“place”放置或使用“lock”锁定的物品可以以固定价格“list（列出）”，允许任何人从Kiosk“purchase（购买）”。在列出时，不能获取或修改项目。但是，通过“borrow（借用）”调用进行的不可变借用仍然可用。“delist”函数将资产返回到之前的状态。
///
/// - `listed_exclusively` - 通过“list_with_purchase_cap”函数列出商品（并创建“PurchaseCap”）。以这种方式列出时，除非返回“PurchaseCap”，否则无法将商品“delist(下架)”。在此项目状态下可用的所有操作都需要“PurchaseCap”：
///
/// 1. `purchase_with_cap` -以等于或高于“PurchaseCap”中设定的“min_price”的价格购买该商品。
/// 2. `return_purchase_cap` - 返回 'PurchaseCap' 并将资产恢复到之前的状态
///
/// 当一个项目被单独列出时，它不能被修改或获取，丢失“PurchaseCap”会将该项目永久锁定在Kiosk中。因此，建议仅在受信任的应用程序中使用“PurchaseCap”功能，而不要将其用于直接交易（例如发送到另一个帐户）。
///
/// ### 针对不同"tracks"使用多种传输策略:(Using multiple Transfer Policies for different "tracks":)
///
/// 每个 `purchase` 或 `purchase_with_purchase_cap` 都会创建一个 `TransferRequest`，这是一个必须在匹配的 `TransferPolicy` 中解决的“烫手山芋”，才能让交易通过。尽管默认情况下，通常应该只存在一个与 `T` 对应的 `TransferPolicy<T>`， 但实际上可以有多个，每个都有自己的一套规则。
///
/// ### Examples:
/// 
///  - 我为所有人创建了一个带有“Royalty Rule（版税规则）”的 `TransferPolicy`
/// - 我为持有“Club Membership（俱乐部会员）”物品的人创建了一个特殊的 `TransferPolicy`，
///   这样他们就不需要支付任何费用
/// - 我创建并包装了一个 `TransferPolicy`，
///   使得我的游戏玩家可以在游戏中的 `Kiosk` 之间无偿转移物品（甚至可能通过设置 0 的 SUI PurchaseCap 而无需支付任何费用）
///
/// ```
/// Kiosk -> (Item, TransferRequest)
/// ... TransferRequest ------> Common Transfer Policy
/// ... TransferRequest ------> In-game Wrapped Transfer Policy
/// ... TransferRequest ------> Club Membership Transfer Policy
/// ```
///
/// 有关它们如何运行的更多详细信息，请参见 `transfer_policy` 模块。
module sui::kiosk {
    use sui::dynamic_object_field as dof;
    use sui::dynamic_field as df;
    use sui::transfer_policy::{
        Self,
        TransferPolicy,
        TransferRequest
    };
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::event;

    /// 允许调用 `cap.kiosk()` 从 `KioskOwnerCap` 中检索 `for` 字段。
    /// 将当前模块中的kiosk_owner_cap_for函数导出，并且在使用这个函数时，可以通过KioskOwnerCap.kiosk来引用它。这种用法通常用于模块重组或为了提高可读性，避免名称冲突等情况。
    public use fun kiosk_owner_cap_for as KioskOwnerCap.kiosk;

    // 获取访问权限:
    // - `place_internal`
    // - `lock_internal`
    // - `uid_mut_internal`

    /// 错误码：
    /// 尝试提取收益时，发送者不是所有者。
    const ENotOwner: u64 = 0;
    /// 支付的货币与报价不符。
    const EIncorrectAmount: u64 = 1;
    /// 尝试提取比存储金额更高的金额。
    const ENotEnough: u64 = 2;
    /// 尝试关闭一个 Kiosk 时，里面还有物品。
    const ENotEmpty: u64 = 3;
    /// 尝试取走一个已发行 PurchaseCap 的物品。
    const EListedExclusively: u64 = 4;
    /// PurchaseCap 与 Kiosk 不匹配。
    const EWrongKiosk: u64 = 5;
    /// 尝试排他性列出一个已经列出的物品。
    const EAlreadyListed: u64 = 6;
    /// 在 allow_extensions 设置为 false 时尝试调用 uid_mut。
    const EUidAccessNotAllowed: u64 = 7;
    /// 尝试取走一个被锁定的物品。
    const EItemLocked: u64 = 8;
    /// 取走或可变借用一个已列出的物品
    const EItemIsListed: u64 = 9;
    /// 物品与 return_val 中的 Borrow 不匹配。
    const EItemMismatch: u64 = 10;
    /// 尝试借用时未找到物品。
    const EItemNotFound: u64 = 11;
    /// 取消列出一个未被列出的物品。
    const ENotListed: u64 = 12;

    /// 一个允许在“kiosk”生态系统内出售收藏品的对象。
    /// 默认情况下，提供公开列出商品的功能 - 任何人都可以购买，为创作者提供保证，每次转移都需要通过“TransferPolicy”获得批准。
    public struct Kiosk has key, store {
        id: UID,
        /// Kiosk的余额 - 所有销售利润都存储在这里。
        profits: Balance<SUI>,
        /// 始终指向交易的 `sender`。
        /// 可以通过调用带有 Cap 的 `set_owner` 进行更改。
        owner: address,
        /// 存储在 Kiosk 中的物品数量。用于允许解包空的 Kiosk（如果它已被包装或仅有一个所有者）。
        item_count: u32,
        /// [已弃用] 请不要使用 `allow_extensions` 和匹配的 `set_allow_extensions` 函数——这是一个遗留功能，正在被 `kiosk_extension` 模块及其扩展API所取代。
        ///
        /// 当设置为 `true` 时，公开 `uid_mut`，默认设置为 `false`。
        allow_extensions: bool
    }

    /// 授予持有者在 `Kiosk` 中 `place` 和 `take` 物品的权利的能力，
    /// 以及将其列出('list')和与购买能力一起列出（`list_with_purchase_cap`）。
    public struct KioskOwnerCap has key, store {
        id: UID,
        `for`: ID
    }

    /// 一种锁定物品并授予权限以在 `Kiosk` 中以不低于 `min_price` 的任何价格购买它的能力。
    ///
    /// 允许排他性列出：只有 `PurchaseCap` 的持有者可以购买该资产。但是，该能力应谨慎使用，因为丢失它将锁定 `Kiosk` 中的资产。
    ///
    /// “PurchaseCap”的主要应用是在“Kiosk”之上构建扩展。
    public struct PurchaseCap<phantom T: key + store> has key, store {
        id: UID,
        /// 该能力所属的 `Kiosk` 的 ID。
        kiosk_id: ID,
        /// 已列出物品的 ID。
        item_id: ID,
        /// 物品可以购买的最低价格。
        min_price: u64
    }

    // === 工具 ===

    /// 确保物品在使用 `borrow_val` 调用后被归还的标记。
    public struct Borrow { kiosk_id: ID, item_id: ID }

    // === 动态字段键 ===

    /// 放置到 kiosk 中的物品的动态字段键。
    public struct Item has store, copy, drop { id: ID }

    /// Dynamic field key for an active offer to purchase the T. If an
    /// item is listed without a `PurchaseCap`, exclusive is set to `false`.
    /// 用于购买 T 的有效报价的动态字段键。如果物品在没有 `PurchaseCap` 的情况下列出，则将 `is_exclusive` 设置为 `false`。
    public struct Listing has store, copy, drop { id: ID, is_exclusive: bool }

    /// Dynamic field key which marks that an item is locked in the `Kiosk` and
    /// can't be `take`n. The item then can only be listed / sold via the PurchaseCap.
    /// Lock is released on `purchase`.
    /// 标记某个物品已在 `Kiosk` 中锁定并且无法被 `take` 的动态字段键。此时，物品只能通过 PurchaseCap 列出/出售。
    /// 锁定在 `purchase` 时解除。
    public struct Lock has store, copy, drop { id: ID }

    // === 事件Events ===

    /// Emitted when an item was listed by the safe owner. Can be used
    /// to track available offers anywhere on the network; the event is
    /// type-indexed which allows for searching for offers of a specific `T`
    /// 当物品由保险箱所有者列出时触发。可用于在网络上的任何地方跟踪可用的报价；该事件是类型索引的，这允许搜索特定 `T` 的报价。
    public struct ItemListed<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        price: u64
    }

    /// Emitted when an item was purchased from the `Kiosk`. Can be used
    /// to track finalized sales across the network. The event is emitted
    /// in both cases: when an item is purchased via the `PurchaseCap` or
    /// when it's purchased directly (via `list` + `purchase`).
    ///
    /// The `price` is also emitted and might differ from the `price` set
    /// in the `ItemListed` event. This is because the `PurchaseCap` only
    /// sets a minimum price for the item, and the actual price is defined
    /// by the trading module / extension.
    /// 
    /// 当物品从 `Kiosk` 中购买时触发。可用于跟踪网络上的最终销售情况。事件在两种情况下都会触发：当物品通过 `PurchaseCap` 购买时，或直接购买（通过 `list` + `purchase`）。
    ///
    /// `price` 也会被触发，并且可能与 `ItemListed` 事件中设置的 `price` 不同。这是因为 `PurchaseCap` 仅设置了物品的最低价格，实际价格由交易模块/扩展定义。

    public struct ItemPurchased<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        price: u64
    }

    /// Emitted when an item was delisted by the safe owner. Can be used
    /// to close tracked offers.
    /// 当物品被保险箱所有者取消列出时触发。可用于关闭跟踪的报价。
    public struct ItemDelisted<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID
    }

    // === Kiosk 打包和解包 Kiosk packing and unpacking ===

    #[allow(lint(self_transfer, share_owned))]
    /// Creates a new Kiosk in a default configuration: sender receives the
    /// `KioskOwnerCap` and becomes the Owner, the `Kiosk` is shared.
    ///  创建一个默认配置的新 Kiosk：发送者接收 `KioskOwnerCap` 并成为所有者，`Kiosk` 被共享。
    entry fun default(ctx: &mut TxContext) {
        let (kiosk, cap) = new(ctx);
        sui::transfer::transfer(cap, ctx.sender());
        sui::transfer::share_object(kiosk);
    }

    /// Creates a new `Kiosk` with a matching `KioskOwnerCap`.
    /// 创建一个带有匹配 `KioskOwnerCap` 的新 `Kiosk`。
    public fun new(ctx: &mut TxContext): (Kiosk, KioskOwnerCap) {
        let kiosk = Kiosk {
            id: object::new(ctx),
            profits: balance::zero(),
            owner: ctx.sender(),
            item_count: 0,
            allow_extensions: false
        };

        let cap = KioskOwnerCap {
            id: object::new(ctx),
            `for`: object::id(&kiosk)
        };

        (kiosk, cap)
    }

    /// 解包并销毁 Kiosk，返还利润（即使是 "0"）。
    /// 只有在内部没有物品且未共享“Kiosk”的情况下，“KioskOwnerCap”的持有者才能执行。
    public fun close_and_withdraw(
        self: Kiosk, cap: KioskOwnerCap, ctx: &mut TxContext
    ): Coin<SUI> {
        let Kiosk { id, profits, owner: _, item_count, allow_extensions: _ } = self;
        let KioskOwnerCap { id: cap_id, `for` } = cap;

        assert!(id.to_inner() == `for`, ENotOwner);
        assert!(item_count == 0, ENotEmpty);

        cap_id.delete();
        id.delete();

        profits.into_coin(ctx)
    }

    /// Change the `owner` field to the transaction sender.
    /// The change is purely cosmetical and does not affect any of the
    /// basic kiosk functions unless some logic for this is implemented
    /// in a third party module.
    /// 将 `owner` 字段更改为交易发送者。
    /// 此更改纯粹是外观上的，除非在第三方模块中实现了相应逻辑，否则不会影响任何基本的 Kiosk 功能。
    public fun set_owner(
        self: &mut Kiosk, cap: &KioskOwnerCap, ctx: &TxContext
    ) {
        assert!(self.has_access(cap), ENotOwner);
        self.owner = ctx.sender();
    }

    /// Update the `owner` field with a custom address. Can be used for
    /// implementing a custom logic that relies on the `Kiosk` owner.
    /// 使用自定义地址更新 `owner` 字段。可以用于实现依赖于 `Kiosk` 所有者的自定义逻辑。
    public fun set_owner_custom(
        self: &mut Kiosk, cap: &KioskOwnerCap, owner: address
    ) {
        assert!(self.has_access(cap), ENotOwner);
        self.owner = owner
    }

    // === 在 Kiosk 中放置、锁定和取出物品（Place, Lock and Take from the Kiosk） ===

    /// Place any object into a Kiosk.
    /// Performs an authorization check to make sure only owner can do that.
    /// 将任何对象放入 Kiosk 中。
    /// 进行授权检查以确保只有所有者可以执行此操作。
    public fun place<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, item: T
    ) {
        assert!(self.has_access(cap), ENotOwner);
        self.place_internal(item)
    }

    /// Place an item to the `Kiosk` and issue a `Lock` for it. Once placed this
    /// way, an item can only be listed either with a `list` function or with a
    /// `list_with_purchase_cap`.
    ///
    /// Requires policy for `T` to make sure that there's an issued `TransferPolicy`
    /// and the item can be sold, otherwise the asset might be locked forever.
    /// 
    /// 将物品放入 `Kiosk` 并为其发出 `Lock`。以这种方式放置后，物品只能通过 `list` 函数或 `list_with_purchase_cap` 列出。
    ///
    /// 需要为 `T` 设置策略，以确保已发布 `TransferPolicy` 并且物品可以被出售，否则资产可能会被永久锁定。
    public fun lock<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, _policy: &TransferPolicy<T>, item: T
    ) {
        assert!(self.has_access(cap), ENotOwner);
        self.lock_internal(item)
    }

    /// Take any object from the Kiosk.
    /// Performs an authorization check to make sure only owner can do that.
    /// 从 Kiosk 中取出任何对象。
    /// 进行授权检查以确保只有所有者可以执行此操作。
    public fun take<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID
    ): T {
        assert!(self.has_access(cap), ENotOwner);
        assert!(!self.is_locked(id), EItemLocked);
        assert!(!self.is_listed_exclusively(id), EListedExclusively);
        assert!(self.has_item(id), EItemNotFound);

        self.item_count = self.item_count - 1;
        df::remove_if_exists<Listing, u64>(&mut self.id, Listing { id, is_exclusive: false });
        dof::remove(&mut self.id, Item { id })
    }

    // === 交易功能：列出和购买（Trading functionality: List and Purchase） ===

    /// List the item by setting a price and making it available for purchase.
    /// Performs an authorization check to make sure only owner can sell.
    /// 通过设置价格并使其可供购买来列出物品。
    /// 进行授权检查以确保只有所有者可以出售。
    public fun list<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID, price: u64
    ) {
        assert!(self.has_access(cap), ENotOwner);
        assert!(self.has_item_with_type<T>(id), EItemNotFound);
        assert!(!self.is_listed_exclusively(id), EListedExclusively);

        df::add(&mut self.id, Listing { id, is_exclusive: false }, price);
        event::emit(ItemListed<T> { kiosk: object::id(self), id, price })
    }

    /// Calls `place` and `list` together - simplifies the flow.
    /// 调用 `place` 和 `list` 一起 - 简化流程。
    public fun place_and_list<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, item: T, price: u64
    ) {
        let id = object::id(&item);
        self.place(cap, item);
        self.list<T>(cap, id, price)
    }

    /// Remove an existing listing from the `Kiosk` and keep the item in the
    /// user Kiosk. Can only be performed by the owner of the `Kiosk`.
    /// 从 `Kiosk` 中删除现有的列出物品并将物品保留在用户 Kiosk 中。只能由 `Kiosk` 的所有者执行。
    public fun delist<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID
    ) {
        assert!(self.has_access(cap), ENotOwner);
        assert!(self.has_item_with_type<T>(id), EItemNotFound);
        assert!(!self.is_listed_exclusively(id), EListedExclusively);
        assert!(self.is_listed(id), ENotListed);

        df::remove<Listing, u64>(&mut self.id, Listing { id, is_exclusive: false });
        event::emit(ItemDelisted<T> { kiosk: object::id(self), id })
    }

    /// Make a trade: pay the owner of the item and request a Transfer to the `target`
    /// kiosk (to prevent item being taken by the approving party).
    ///
    /// Received `TransferRequest` needs to be handled by the publisher of the T,
    /// if they have a method implemented that allows a trade, it is possible to
    /// request their approval (by calling some function) so that the trade can be
    /// finalized.
    /// 进行交易：支付物品的所有者并请求将其转移到 `target` Kiosk（以防止物品被批准方取走）。
    ///
    /// 如果 `TransferRequest` 被 T 的发布者处理，并且他们实现了允许交易的方法，则可以请求他们的批准（通过调用某些函数），以便交易可以最终完成。
    public fun purchase<T: key + store>(
        self: &mut Kiosk, id: ID, payment: Coin<SUI>
    ): (T, TransferRequest<T>) {
        let price = df::remove<Listing, u64>(&mut self.id, Listing { id, is_exclusive: false });
        let inner = dof::remove<Item, T>(&mut self.id, Item { id });

        self.item_count = self.item_count - 1;
        assert!(price == payment.value(), EIncorrectAmount);
        df::remove_if_exists<Lock, bool>(&mut self.id, Lock { id });
        coin::put(&mut self.profits, payment);

        event::emit(ItemPurchased<T> { kiosk: object::id(self), id, price });

        (inner, transfer_policy::new_request(id, price, object::id(self)))
    }

    // ===  交易功能：带有 `PurchaseCap` 的排他性列表(Trading Functionality: Exclusive listing with `PurchaseCap`) ===

    /// Creates a `PurchaseCap` which gives the right to purchase an item
    /// for any price equal or higher than the `min_price`.
    /// 创建一个 `PurchaseCap`，该功能授予购买物品的权利，价格等于或高于 `min_price`。
    public fun list_with_purchase_cap<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID, min_price: u64, ctx: &mut TxContext
    ): PurchaseCap<T> {
        assert!(self.has_access(cap), ENotOwner);
        assert!(self.has_item_with_type<T>(id), EItemNotFound);
        assert!(!self.is_listed(id), EAlreadyListed);

        df::add(&mut self.id, Listing { id, is_exclusive: true }, min_price);

        PurchaseCap<T> {
            min_price,
            item_id: id,
            id: object::new(ctx),
            kiosk_id: object::id(self),
        }
    }

    /// Unpack the `PurchaseCap` and call `purchase`. Sets the payment amount
    /// as the price for the listing making sure it's no less than `min_amount`.
    /// 解包 `PurchaseCap` 并调用 `purchase`。将支付金额设置为列表价格，确保不低于 `min_amount`。
    public fun purchase_with_cap<T: key + store>(
        self: &mut Kiosk, purchase_cap: PurchaseCap<T>, payment: Coin<SUI>
    ): (T, TransferRequest<T>) {
        let PurchaseCap { id, item_id, kiosk_id, min_price } = purchase_cap;
        id.delete();

        let id = item_id;
        let paid = payment.value();
        assert!(paid >= min_price, EIncorrectAmount);
        assert!(object::id(self) == kiosk_id, EWrongKiosk);

        df::remove<Listing, u64>(&mut self.id, Listing { id, is_exclusive: true });

        coin::put(&mut self.profits, payment);
        self.item_count = self.item_count - 1;
        df::remove_if_exists<Lock, bool>(&mut self.id, Lock { id });
        let item = dof::remove<Item, T>(&mut self.id, Item { id });

        (item, transfer_policy::new_request(id, paid, object::id(self)))
    }

    /// Return the `PurchaseCap` without making a purchase; remove an active offer and
    /// allow the item for taking. Can only be returned to its `Kiosk`, aborts otherwise.
    /// 退回 `PurchaseCap` 而不进行购买；删除活跃的报价并允许取出物品。只能退还给其 `Kiosk`，否则中止。
    public fun return_purchase_cap<T: key + store>(
        self: &mut Kiosk, purchase_cap: PurchaseCap<T>
    ) {
        let PurchaseCap { id, item_id, kiosk_id, min_price: _ } = purchase_cap;

        assert!(object::id(self) == kiosk_id, EWrongKiosk);
        df::remove<Listing, u64>(&mut self.id, Listing { id: item_id, is_exclusive: true });
        id.delete()
    }

    /// Withdraw profits from the Kiosk.
    /// 从 Kiosk 提取利润。
    public fun withdraw(
        self: &mut Kiosk, cap: &KioskOwnerCap, amount: Option<u64>, ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(self.has_access(cap), ENotOwner);

        let amount = if (amount.is_some()) {
            let amt = amount.destroy_some();
            assert!(amt <= self.profits.value(), ENotEnough);
            amt
        } else {
            self.profits.value()
        };

        coin::take(&mut self.profits, amount, ctx)
    }

    // === 内部核心(Internal Core) ===

    /// Internal: "lock" an item disabling the `take` action.
    /// 内部：“锁定” 物品，禁用 `take` 操作。
    public(package) fun lock_internal<T: key + store>(self: &mut Kiosk, item: T) {
        df::add(&mut self.id, Lock { id: object::id(&item) }, true);
        self.place_internal(item)
    }

    /// Internal: "place" an item to the Kiosk and increment the item count.
    /// 内部：将物品“放置”到 Kiosk 中并增加物品计数。
    public(package) fun place_internal<T: key + store>(self: &mut Kiosk, item: T) {
        self.item_count = self.item_count + 1;
        dof::add(&mut self.id, Item { id: object::id(&item) }, item)
    }

    /// Internal: get a mutable access to the UID.
    /// 内部：获取对 UID 的可变访问。
    public(package) fun uid_mut_internal(self: &mut Kiosk): &mut UID {
        &mut self.id
    }

    // === Kiosk 字段访问(Kiosk fields access) ===

    /// Check whether the `item` is present in the `Kiosk`.
    /// 检查 `Kiosk` 中是否存在 `item`。
    public fun has_item(self: &Kiosk, id: ID): bool {
        dof::exists_(&self.id, Item { id })
    }

    /// Check whether the `item` is present in the `Kiosk` and has type T.
    /// 检查 `Kiosk` 中是否存在类型为 T 的 `item`。
    public fun has_item_with_type<T: key + store>(self: &Kiosk, id: ID): bool {
        dof::exists_with_type<Item, T>(&self.id, Item { id })
    }

    /// Check whether an item with the `id` is locked in the `Kiosk`. Meaning
    /// that the only two actions that can be performed on it are `list` and
    /// `list_with_purchase_cap`, it cannot be `take`n out of the `Kiosk`.
    /// 检查 `Kiosk` 中的物品是否被锁定。意思是，只有两个操作可以对其执行：`list` 和 `list_with_purchase_cap`，不能将其从 `Kiosk` 中取出。
    public fun is_locked(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Lock { id })
    }

    /// Check whether an `item` is listed (exclusively or non exclusively).
    /// 检查 `item` 是否已被列出（排他性或非排他性）。
    public fun is_listed(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Listing { id, is_exclusive: false })
        || self.is_listed_exclusively(id)
    }

    /// Check whether there's a `PurchaseCap` issued for an item.
    /// 检查是否为物品发出了 `PurchaseCap`。
    public fun is_listed_exclusively(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Listing { id, is_exclusive: true })
    }

    /// Check whether the `KioskOwnerCap` matches the `Kiosk`.
    /// 检查 `KioskOwnerCap` 是否与 `Kiosk` 匹配。
    public fun has_access(self: &mut Kiosk, cap: &KioskOwnerCap): bool {
        object::id(self) == cap.`for`
    }

    /// Access the `UID` using the `KioskOwnerCap`.
    /// 使用 `KioskOwnerCap` 访问 `UID`。
    public fun uid_mut_as_owner(
        self: &mut Kiosk, cap: &KioskOwnerCap
    ): &mut UID {
        assert!(self.has_access(cap), ENotOwner);
        &mut self.id
    }

    /// [DEPRECATED]
    /// Allow or disallow `uid` and `uid_mut` access via the `allow_extensions`
    /// setting.
    public fun set_allow_extensions(
        self: &mut Kiosk, cap: &KioskOwnerCap, allow_extensions: bool
    ) {
        assert!(self.has_access(cap), ENotOwner);
        self.allow_extensions = allow_extensions;
    }

    /// Get the immutable `UID` for dynamic field access.
    /// Always enabled.
    ///
    /// Given the &UID can be used for reading keys and authorization,
    /// its access
    /// 
    /// 获取用于动态字段访问的不可变 `UID`。
    /// 始终启用。
    ///
    /// 由于 &UID 可用于读取密钥和授权，    
    public fun uid(self: &Kiosk): &UID {
        &self.id
    }

    /// Get the mutable `UID` for dynamic field access and extensions.
    /// Aborts if `allow_extensions` set to `false`.
    /// 获取用于动态字段访问和扩展的可变 `UID`。
    /// 如果 `allow_extensions` 设置为 `false`，则中止。
    public fun uid_mut(self: &mut Kiosk): &mut UID {
        assert!(self.allow_extensions, EUidAccessNotAllowed);
        &mut self.id
    }

    /// Get the owner of the Kiosk.
    public fun owner(self: &Kiosk): address {
        self.owner
    }

    /// Get the number of items stored in a Kiosk.
    public fun item_count(self: &Kiosk): u32 {
        self.item_count
    }

    /// Get the amount of profits collected by selling items.
    /// 获取通过销售物品收集的利润金额。
    public fun profits_amount(self: &Kiosk): u64 {
        self.profits.value()
    }

    /// Get mutable access to `profits` - owner only action.
    public fun profits_mut(self: &mut Kiosk, cap: &KioskOwnerCap): &mut Balance<SUI> {
        assert!(self.has_access(cap), ENotOwner);
        &mut self.profits
    }

    // ===  物品借用 (Item borrowing) ===

    #[syntax(index)]
    /// Immutably borrow an item from the `Kiosk`. Any item can be `borrow`ed
    /// at any time.
    /// 从 `Kiosk` 中不可变借用一个物品。任何物品可以随时 `borrow`。
    public fun borrow<T: key + store>(
        self: &Kiosk, cap: &KioskOwnerCap, id: ID
    ): &T {
        assert!(object::id(self) == cap.`for`, ENotOwner);
        assert!(self.has_item(id), EItemNotFound);

        dof::borrow(&self.id, Item { id })
    }

    #[syntax(index)]
    /// Mutably borrow an item from the `Kiosk`.
    /// Item can be `borrow_mut`ed only if it's not `is_listed`.
    public fun borrow_mut<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID
    ): &mut T {
        assert!(self.has_access(cap), ENotOwner);
        assert!(self.has_item(id), EItemNotFound);
        assert!(!self.is_listed(id), EItemIsListed);

        dof::borrow_mut(&mut self.id, Item { id })
    }

    /// Take the item from the `Kiosk` with a guarantee that it will be returned.
    /// Item can be `borrow_val`-ed only if it's not `is_listed`.
    /// 从 `Kiosk` 中取出物品，并保证它将被归还。
    /// 只有当物品未被 `is_listed` 时，才能 `borrow_val`。
    public fun borrow_val<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID
    ): (T, Borrow) {
        assert!(self.has_access(cap), ENotOwner);
        assert!(self.has_item(id), EItemNotFound);
        assert!(!self.is_listed(id), EItemIsListed);

        (
            dof::remove(&mut self.id, Item { id }),
            Borrow { kiosk_id: object::id(self), item_id: id }
        )
    }

    /// Return the borrowed item to the `Kiosk`. This method cannot be avoided
    /// if `borrow_val` is used.
    /// 将借来的物品归还到 `Kiosk`。如果使用了 `borrow_val`，则此方法无法避免。
    public fun return_val<T: key + store>(
        self: &mut Kiosk, item: T, borrow: Borrow
    ) {
        let Borrow { kiosk_id, item_id } = borrow;

        assert!(object::id(self) == kiosk_id, EWrongKiosk);
        assert!(object::id(&item) == item_id, EItemMismatch);

        dof::add(&mut self.id, Item { id: item_id }, item);
    }

    // === KioskOwnerCap 字段访问 (KioskOwnerCap fields access) ===

    /// Get the `for` field of the `KioskOwnerCap`.
    public fun kiosk_owner_cap_for(cap: &KioskOwnerCap): ID {
        cap.`for`
    }

    // === PurchaseCap 字段访问 (PurchaseCap fields access) ===

    /// Get the `kiosk_id` from the `PurchaseCap`.
    public fun purchase_cap_kiosk<T: key + store>(self: &PurchaseCap<T>): ID {
        self.kiosk_id
    }

    /// Get the `Item_id` from the `PurchaseCap`.
    public fun purchase_cap_item<T: key + store>(self: &PurchaseCap<T>): ID {
        self.item_id
    }

    /// Get the `min_price` from the `PurchaseCap`.
    public fun purchase_cap_min_price<T: key + store>(self: &PurchaseCap<T>): u64 {
        self.min_price
    }
}
