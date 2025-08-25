import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'cart_screen.dart';

class ProductListScreen extends StatefulWidget {
  final String city;
  final String shopId;
  final String shopName;

  const ProductListScreen({
    super.key,
    required this.city,
    required this.shopId,
    required this.shopName,
  });

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  final dbRef = FirebaseDatabase.instance.ref();
  final user = FirebaseAuth.instance.currentUser;
  final ScrollController _scrollController = ScrollController();

  List<Map<String, dynamic>> allProducts = [];
  List<Map<String, dynamic>> _filteredCache = [];
  List<Map<String, dynamic>> visibleProducts = [];
  List<bool> fadeStates = [];

  Map<String, dynamic> cartItems = {};

  // sequential loading
  int _nextIndexToAppend = 0;
  bool _waitingForCard = false;
  Timer? _advanceFallback; // safety timer
  final Set<String> _cardBuiltKeyOnce = {}; // track by key to survive trimming

  // cap window to reduce memory
  static const int _maxWindow = 40;

  bool isLoading = true;
  String searchQuery = "";

  // search debounce
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    fetchCart();
    fetchProducts();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchDebounce?.cancel();
    _advanceFallback?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 600) {
      _appendNext();
    }
  }

  Future<void> fetchCart() async {
    if (user == null) return;
    final snapshot = await dbRef.child("users/${user!.uid}/cart").get();
    if (snapshot.exists) {
      setState(() {
        cartItems = Map<String, dynamic>.from(snapshot.value as Map);
      });
    }
  }

  Future<void> fetchProducts() async {
    final snapshot = await dbRef
        .child("cities/${widget.city}/shops/${widget.shopId}/products")
        .get();

    allProducts = [];
    for (var item in snapshot.children) {
      final data = Map<String, dynamic>.from(item.value as Map);
      allProducts.add({
        "key": item.key,
        "name": data["name"] ?? "",
        "price": data["price"] ?? 0,
        "mrp": data["mrp"] ?? 0,
        "image": data["imageUrl"] ?? "",
        "stock": data["stock"] ?? 0,
        "quantity": data["quantity"] ?? "",
      });
    }

    _rebuildFilterAndStart("");
    setState(() => isLoading = false);
  }

  void applySearch(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      _rebuildFilterAndStart(query);
    });
  }

  void _rebuildFilterAndStart(String query) {
    searchQuery = query.toLowerCase();
    _filteredCache = allProducts
        .where((p) => p["name"].toString().toLowerCase().contains(searchQuery))
        .toList();

    setState(() {
      visibleProducts = [];
      fadeStates = [];
      _nextIndexToAppend = 0;
      _waitingForCard = false;
      _cardBuiltKeyOnce.clear();
    });

    _appendNext();
  }

  void _appendNext() {
    if (_waitingForCard) return;
    if (_nextIndexToAppend >= _filteredCache.length) return;

    final next = _filteredCache[_nextIndexToAppend];
    final nextKey = (next["key"] ?? "").toString();

    setState(() {
      visibleProducts.add(next);
      fadeStates.add(false);
      _waitingForCard = true;
    });

    _nextIndexToAppend++;

    // Precache image to reduce jank
    final url = (next["image"] ?? "").toString();
    if (url.isNotEmpty && mounted) {
      precacheImage(NetworkImage(url), context);
    }

    // Trim older items (keep newest _maxWindow)
    _trimWindowKeepNewest();

    // Safety: if card never posts built, advance anyway
    _advanceFallback?.cancel();
    _advanceFallback = Timer(const Duration(milliseconds: 900), () {
      if (mounted) _onCardBuiltByKey(nextKey);
    });
  }

  void _trimWindowKeepNewest() {
    final overflow = visibleProducts.length - _maxWindow;
    if (overflow > 0) {
      visibleProducts.removeRange(0, overflow);
      fadeStates.removeRange(0, overflow);
      // No need to adjust _cardBuiltKeyOnce
    }
  }

  void _onCardBuiltByKey(String key) {
    if (!mounted) return;

    final idx = visibleProducts.indexWhere(
          (e) => (e["key"] ?? "").toString() == key,
    );

    if (idx >= 0 && idx < fadeStates.length && !fadeStates[idx]) {
      setState(() => fadeStates[idx] = true);
    }

    if (_waitingForCard) {
      _waitingForCard = false;
      _advanceFallback?.cancel();
      _appendNext();
    }
  }

  Future<void> toggleCart(Map<String, dynamic> p) async {
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please login first")),
      );
      return;
    }

    final key = p["key"];
    final ref = dbRef.child("users/${user!.uid}/cart/$key");

    if (cartItems.containsKey(key)) {
      await ref.remove();
      cartItems.remove(key);
    } else {
      cartItems[key] = {
        "name": p["name"],
        "price": p["price"],
        "mrp": p["mrp"],
        "unit": p["quantity"],
        "image": p["image"],
        "quantity": 1,
        "status": 'ordered',
        "city": widget.city,
        "shopId": widget.shopId,
      };
      await ref.set(cartItems[key]);
    }

    setState(() {});
  }

  double getCartTotal() {
    return cartItems.entries.fold(0.0, (total, entry) {
      final p = entry.value;
      return total +
          (double.tryParse(p["price"].toString()) ?? 0) * (p["quantity"] ?? 1);
    });
  }

  bool isInCart(String key) => cartItems.containsKey(key);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width < 700 ? 2 : 4;

    return Scaffold(
      backgroundColor: const Color(0xFFFFF5E1),
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: Text(widget.shopName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              onChanged: applySearch,
              decoration: InputDecoration(
                hintText: "Search product...",
                filled: true,
                fillColor: Colors.white,
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
        children: [
          GridView.builder(
            controller: _scrollController,
            physics: const ClampingScrollPhysics(),
            cacheExtent: 900,
            itemCount: visibleProducts.length +
                ((_nextIndexToAppend < _filteredCache.length) ? 1 : 0),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 100),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.58,
            ),
            itemBuilder: (_, i) {
              if (i >= visibleProducts.length) {
                return const Center(child: CircularProgressIndicator());
              }

              final p = visibleProducts[i];
              final fadeIn = fadeStates.length > i ? fadeStates[i] : true;
              final key = (p["key"] ?? "").toString();

              if (!_cardBuiltKeyOnce.contains(key)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && !_cardBuiltKeyOnce.contains(key)) {
                    _cardBuiltKeyOnce.add(key);
                    _onCardBuiltByKey(key);
                  }
                });
              }

              return AnimatedOpacity(
                opacity: fadeIn ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeIn,
                child: buildProductCard(p),
              );
            },
          ),
          if (cartItems.isNotEmpty)
            Positioned(
              bottom: 15,
              left: 10,
              right: 10,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 20,
                  ),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CartScreen()),
                  );
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("${cartItems.length} item(s)",
                        style: const TextStyle(color: Colors.white)),
                    Row(
                      children: [
                        Text(
                          "₹${getCartTotal().toStringAsFixed(0)}",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Icon(Icons.arrow_forward,
                            color: Colors.white),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget buildProductCard(Map<String, dynamic> p) {
    final price = p["price"] * 1.0;
    final mrp = p["mrp"] * 1.0;
    final discount = mrp > price ? ((1 - (price / mrp)) * 100).round() : 0;
    final inCart = isInCart(p["key"]);
    final hasImage = (p["image"] ?? "").toString().isNotEmpty;

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProductDetailScreen(
              city: widget.city,
              shopId: widget.shopId,
              product: p,
            ),
          ),
        ).then((_) {
          fetchCart();
          setState(() {});
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: hasImage
                          ? Image.network(
                        p["image"],
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        loadingBuilder: (ctx, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            color: Colors.grey[200],
                            child: const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        },
                      )
                          : Container(
                        color: Colors.grey[200],
                        child: const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    p["name"],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text("Qty: ${p['quantity']}",
                      style: const TextStyle(fontSize: 12)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text("₹${price.toStringAsFixed(0)}"),
                      if (discount > 0) ...[
                        const SizedBox(width: 5),
                        Text(
                          "₹${mrp.toStringAsFixed(0)}",
                          style: const TextStyle(
                            decoration: TextDecoration.lineThrough,
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ]
                    ],
                  ),
                  const Spacer(),
                  p["stock"] == 0
                      ? const OutlinedButton(
                    onPressed: null,
                    child: Text("Out of Stock",
                        style: TextStyle(color: Colors.red)),
                  )
                      : OutlinedButton(
                    onPressed: () => toggleCart(p),
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                      inCart ? Colors.green : Colors.black,
                      side: BorderSide(
                          color: inCart ? Colors.green : Colors.grey),
                    ),
                    child: Text(inCart ? "REMOVE" : "ADD"),
                  ),
                ],
              ),
            ),
            if (discount > 0)
              Positioned(
                top: 0,
                left: 0,
                child: Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: Text(
                    "$discount% OFF",
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =================== EXTRA SCREEN IN SAME FILE ===================

class ProductDetailScreen extends StatefulWidget {
  final String city;
  final String shopId;
  final Map<String, dynamic> product;

  const ProductDetailScreen({
    super.key,
    required this.city,
    required this.shopId,
    required this.product,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  final dbRef = FirebaseDatabase.instance.ref();
  final user = FirebaseAuth.instance.currentUser;

  Map<String, dynamic> cartItems = {};
  bool isLoading = true;

  // Related products
  List<Map<String, dynamic>> relatedProducts = [];

  @override
  void initState() {
    super.initState();
    _fetchCart();
    _fetchRelatedProducts();
  }

  Future<void> _fetchCart() async {
    if (user == null) {
      setState(() {
        cartItems = {};
        isLoading = false;
      });
      return;
    }
    final snap = await dbRef.child("users/${user!.uid}/cart").get();
    if (snap.exists) {
      cartItems = Map<String, dynamic>.from(snap.value as Map);
    } else {
      cartItems = {};
    }
    setState(() => isLoading = false);
  }

  Future<void> _fetchRelatedProducts() async {
    final snapshot = await dbRef
        .child("cities/${widget.city}/shops/${widget.shopId}/products")
        .get();

    final currentKey = (widget.product["key"] ?? "").toString();
    final List<Map<String, dynamic>> list = [];

    for (var item in snapshot.children) {
      final data = Map<String, dynamic>.from(item.value as Map);
      final key = item.key ?? "";
      if (key == currentKey) continue; // exclude current product
      list.add({
        "key": key,
        "name": data["name"] ?? "",
        "price": data["price"] ?? 0,
        "mrp": data["mrp"] ?? 0,
        "image": data["imageUrl"] ?? "",
        "stock": data["stock"] ?? 0,
        "quantity": data["quantity"] ?? "",
      });
    }

    setState(() {
      // optional: limit to 12 to keep UI snappy
      relatedProducts = list.take(12).toList();
    });
  }

  bool _isInCart(String key) => cartItems.containsKey(key);

  Future<void> _toggleCart() async {
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please login first")),
      );
      return;
    }

    final key = widget.product["key"];
    final ref = dbRef.child("users/${user!.uid}/cart/$key");

    if (_isInCart(key)) {
      await ref.remove();
      cartItems.remove(key);
    } else {
      cartItems[key] = {
        "name": widget.product["name"],
        "price": widget.product["price"],
        "mrp": widget.product["mrp"],
        "unit": widget.product["quantity"],
        "image": widget.product["image"],
        "quantity": 1,
        "status": "ordered",
        "city": widget.city,
        "shopId": widget.shopId,
      };
      await ref.set(cartItems[key]);
    }

    setState(() {});
  }

  // For related product cards
  bool _isInCartFor(String key) => cartItems.containsKey(key);

  Future<void> _toggleCartFor(Map<String, dynamic> p) async {
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please login first")),
      );
      return;
    }

    final key = p["key"];
    final ref = dbRef.child("users/${user!.uid}/cart/$key");

    if (_isInCartFor(key)) {
      await ref.remove();
      cartItems.remove(key);
    } else {
      cartItems[key] = {
        "name": p["name"],
        "price": p["price"],
        "mrp": p["mrp"],
        "unit": p["quantity"],
        "image": p["image"],
        "quantity": 1,
        "status": "ordered",
        "city": widget.city,
        "shopId": widget.shopId,
      };
      await ref.set(cartItems[key]);
    }

    setState(() {});
  }

  double _getCartTotal() {
    return cartItems.entries.fold(0.0, (total, e) {
      final p = e.value;
      return total +
          (double.tryParse(p["price"].toString()) ?? 0) *
              (p["quantity"] ?? 1);
    });
  }

  // === EXACT same product card UI & navigation as ProductListScreen ===
  Widget _relatedProductCard(Map<String, dynamic> p) {
    final price = p["price"] * 1.0;
    final mrp = p["mrp"] * 1.0;
    final discount = mrp > price ? ((1 - (price / mrp)) * 100).round() : 0;
    final inCart = _isInCartFor(p["key"]);
    final hasImage = (p["image"] ?? "").toString().isNotEmpty;

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProductDetailScreen(
              city: widget.city,
              shopId: widget.shopId,
              product: p,
            ),
          ),
        ).then((_) async {
          // refresh local cart after returning
          await _fetchCart();
          setState(() {});
        });
      },
      child: Container(
        width: 180, // fixed width for horizontal list
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: hasImage
                          ? Image.network(
                        p["image"],
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        loadingBuilder: (ctx, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            color: Colors.grey[200],
                            child: const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        },
                      )
                          : Container(
                        color: Colors.grey[200],
                        child: const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    p["name"],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text("Qty: ${p['quantity']}",
                      style: const TextStyle(fontSize: 12)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text("₹${price.toStringAsFixed(0)}"),
                      if (discount > 0) ...[
                        const SizedBox(width: 5),
                        Text(
                          "₹${mrp.toStringAsFixed(0)}",
                          style: const TextStyle(
                            decoration: TextDecoration.lineThrough,
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ]
                    ],
                  ),
                  const Spacer(),
                  p["stock"] == 0
                      ? const OutlinedButton(
                    onPressed: null,
                    child: Text(
                      "Out of Stock",
                      style: TextStyle(color: Colors.red),
                    ),
                  )
                      : OutlinedButton(
                    onPressed: () => _toggleCartFor(p),
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                      inCart ? Colors.green : Colors.black,
                      side: BorderSide(
                        color: inCart ? Colors.green : Colors.grey,
                      ),
                    ),
                    child: Text(inCart ? "REMOVE" : "ADD"),
                  ),
                ],
              ),
            ),
            if (discount > 0)
              Positioned(
                top: 0,
                left: 0,
                child: Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: Text(
                    "$discount% OFF",
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
  // ===================================================================

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final price = (p["price"] ?? 0) * 1.0;
    final mrp = (p["mrp"] ?? 0) * 1.0;
    final discount = mrp > price ? ((1 - (price / mrp)) * 100).round() : 0;
    final inCart = _isInCart(p["key"]);

    return Scaffold(
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: Text(
          p["name"] ?? "",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
        children: [
          ListView(
            cacheExtent: 900,
            padding: const EdgeInsets.all(16),
            children: [
              // Product Name - full width
              Text(
                p["name"] ?? "",
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 12),

              // Product Image
              AspectRatio(
                aspectRatio: 1.2,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: (p["image"] ?? "").toString().isNotEmpty
                      ? Image.network(
                    p["image"],
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    loadingBuilder: (ctx, child, progress) {
                      if (progress == null) return child;
                      return Container(
                        color: Colors.grey[200],
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      );
                    },
                  )
                      : Container(
                    color: Colors.grey[200],
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Price + Discount BELOW Image
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "₹${price.toStringAsFixed(0)}",
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (discount > 0)
                    Text(
                      "₹${mrp.toStringAsFixed(0)}",
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                  if (discount > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "$discount% OFF",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),

              // Quantity Info
              if ((p['quantity'] ?? '').toString().isNotEmpty)
                Text(
                  "Quantity: ${p['quantity']}",
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 20),

              // BIG CENTERED ADD/REMOVE BUTTON
              Center(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.6,
                  height: 50,
                  child: p["stock"] == 0
                      ? OutlinedButton(
                    onPressed: null,
                    child: const Text(
                      "Out of Stock",
                      style: TextStyle(color: Colors.red),
                    ),
                  )
                      : ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                      inCart ? Colors.red : Colors.green,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _toggleCart,
                    child: Text(
                      inCart ? "REMOVE" : "ADD",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // ======= RELATED PRODUCTS (same card UI & navigation) =======
              if (relatedProducts.isNotEmpty) ...[
                const Text(
                  "Related products",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 305, // enough to fit the same card layout nicely
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: relatedProducts.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (_, i) =>
                        _relatedProductCard(relatedProducts[i]),
                  ),
                ),
              ],
              // ============================================================

              const SizedBox(height: 120),
            ],
          ),

          // Cart Summary Button at Bottom
          if (cartItems.isNotEmpty)
            Positioned(
              bottom: 15,
              left: 10,
              right: 10,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 20),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const CartScreen()),
                  );
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("${cartItems.length} item(s)",
                        style: const TextStyle(color: Colors.white)),
                    Row(
                      children: [
                        Text(
                          "₹${_getCartTotal().toStringAsFixed(0)}",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Icon(Icons.arrow_forward,
                            color: Colors.white),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
