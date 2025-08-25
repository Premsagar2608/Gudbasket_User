// ... (keep your existing imports)
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // for FilteringTextInputFormatter
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';

import 'product_list_screen.dart';
import 'orders_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final dbRef = FirebaseDatabase.instance.ref();
  final auth = FirebaseAuth.instance;
  final ScrollController _scrollController = ScrollController();

  String? selectedCity;
  List<String> cities = [];
  List<Map<String, dynamic>> allShops = [];
  List<Map<String, dynamic>> displayedShops = [];
  String? lastKey;
  bool isLoading = false;
  bool hasMore = true;
  int pageSize = 6;
  String searchQuery = "";
  User? currentUser;
  String? userName;
  String? shopIdForAdmin;
  Position? currentPosition;

  bool _authPromptShown = false; // avoid showing dialog multiple times

  @override
  void initState() {
    super.initState();
    currentUser = auth.currentUser;
    if (currentUser != null) fetchUserDetails();
    getCurrentLocation();
    loadCachedPreferences();

    // auto-open login if not authenticated
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (auth.currentUser == null && !_authPromptShown) {
        _authPromptShown = true;
        showAuthDialog(startInLogin: true);
      }
    });

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200 &&
          !isLoading &&
          hasMore) {
        fetchShops();
      }
    });
  }

  Future<void> getCurrentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return;
    LocationPermission permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) return;
    currentPosition =
    await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  Future<void> loadCachedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedCities = prefs.getStringList("cachedCities");
    final cachedCity = prefs.getString("selectedCity");
    if (cachedCities != null && cachedCities.isNotEmpty) {
      setState(() {
        cities = cachedCities;
        selectedCity = cachedCity ?? cachedCities.first;
      });
      fetchShops(reset: true);
    }
    fetchCities();
  }

  Future<void> cacheCities(List<String> cities) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList("cachedCities", cities);
  }

  Future<void> cacheSelectedCity(String city) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("selectedCity", city);
  }

  Future<void> fetchUserDetails() async {
    final snap = await dbRef.child("users/${currentUser!.uid}").get();
    if (snap.exists) {
      setState(() {
        userName = snap.child("name").value?.toString();
        shopIdForAdmin = snap.child("shopId").value?.toString();
      });
    }
  }

  void fetchCities() async {
    final snapshot = await dbRef.child("cities").get();
    if (snapshot.exists) {
      final fetched = snapshot.children.map((e) => e.key!).toList();
      cacheCities(fetched);
      setState(() {
        cities = fetched;
        selectedCity ??= fetched.first;
      });
      fetchShops(reset: true);
    }
  }

  void fetchShops({bool reset = false}) async {
    if (selectedCity == null || isLoading || !hasMore) return;
    setState(() => isLoading = true);
    if (reset) {
      lastKey = null;
      allShops.clear();
      displayedShops.clear();
      hasMore = true;
    }

    Query query = dbRef
        .child("cities/$selectedCity/shops")
        .orderByKey()
        .limitToFirst(pageSize + 1);
    if (lastKey != null) query = query.startAfter([lastKey]);

    final snapshot = await query.get();
    List<Map<String, dynamic>> newShops = [];
    String? newLastKey;

    for (var shop in snapshot.children) {
      final data = Map<String, dynamic>.from(shop.value as Map);
      newShops.add({
        "id": shop.key,
        "name": data["shopName"] ?? "Unnamed Shop",
        "banner": data["bannerUrl"] ?? "",
      });
      newLastKey = shop.key;
    }

    setState(() {
      lastKey = newLastKey;
      allShops.addAll(newShops);
      displayedShops = applySearch(allShops, searchQuery);
      isLoading = false;
      if (newShops.length < pageSize) hasMore = false;
    });
  }

  List<Map<String, dynamic>> applySearch(
      List<Map<String, dynamic>> shops, String query) {
    return query.isEmpty
        ? shops
        : shops
        .where((s) =>
        s["name"].toString().toLowerCase().contains(query.toLowerCase()))
        .toList();
  }

  Widget _buildBannerImage(String banner) {
    if (banner.isEmpty) {
      return Container(
        color: Colors.grey[200],
        child: const Center(
          child: Icon(Icons.store, size: 40, color: Colors.grey),
        ),
      );
    }

    try {
      if (banner.startsWith("http")) {
        return Image.network(
          banner,
          fit: BoxFit.cover,
          width: double.infinity,
          errorBuilder: (_, __, ___) => Container(
            color: Colors.grey[200],
            child: const Center(
              child: Icon(Icons.broken_image, size: 40, color: Colors.grey),
            ),
          ),
        );
      } else {
        final Uint8List bytes = base64Decode(banner);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          width: double.infinity,
          errorBuilder: (_, __, ___) => Container(
            color: Colors.grey[200],
            child: const Center(
              child: Icon(Icons.broken_image, size: 40, color: Colors.grey),
            ),
          ),
        );
      }
    } catch (_) {
      return Container(
        color: Colors.grey[200],
        child: const Center(
          child: Icon(Icons.broken_image, size: 40, color: Colors.grey),
        ),
      );
    }
  }

  // ------------------------ AUTH DIALOG ------------------------

  void showAuthDialog({required bool startInLogin}) {
    showDialog(
      context: context,
      barrierDismissible: false, // force a choice
      builder: (ctx) {
        bool isLogin = startInLogin;
        final loginKey = GlobalKey<FormState>();
        final signupKey = GlobalKey<FormState>();

        String lEmail = '', lPhonePwd = '';
        bool lObscure = true;
        bool lBusy = false;

        String sName = '', sEmail = '', sPhonePwd = '', sPhoneConfirm = '';
        bool sObscure1 = true, sObscure2 = true;
        bool sBusy = false;

        void switchMode() {
          isLogin = !isLogin;
          (ctx as Element).markNeedsBuild();
        }

        Future<void> doLogin() async {
          if (!loginKey.currentState!.validate()) return;
          try {
            (ctx as Element).markNeedsBuild();
            lBusy = true;
            await auth.signInWithEmailAndPassword(
              email: lEmail.trim(),
              password: lPhonePwd.trim(), // phone used as password
            );
            currentUser = auth.currentUser;
            await fetchUserDetails();
            if (mounted) Navigator.of(ctx).pop();
            setState(() {}); // refresh header etc.
          } on FirebaseAuthException catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(e.message ?? 'Login failed')),
            );
          } finally {
            lBusy = false;
            (ctx as Element).markNeedsBuild();
          }
        }

        Future<void> doSignup() async {
          if (!signupKey.currentState!.validate()) return;
          try {
            (ctx as Element).markNeedsBuild();
            sBusy = true;
            final cred = await auth.createUserWithEmailAndPassword(
              email: sEmail.trim(),
              password: sPhonePwd.trim(), // phone used as password
            );
            final uid = cred.user?.uid;
            await dbRef.child("users/$uid").set({
              "name": sName.trim(),
              "email": sEmail.trim(),
              "phone": sPhonePwd.trim(),
            });
            currentUser = cred.user;
            userName = sName.trim();
            if (mounted) Navigator.of(ctx).pop();
            setState(() {}); // refresh header etc.
          } on FirebaseAuthException catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(e.message ?? 'Signup failed')),
            );
          } finally {
            sBusy = false;
            (ctx as Element).markNeedsBuild();
          }
        }

        InputDecoration _dec(String label, {IconData? icon}) => InputDecoration(
          labelText: label,
          prefixIcon: icon != null ? Icon(icon) : null,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        );

        Widget _closeButton() => Positioned(
          right: 8,
          top: 8,
          child: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        );

        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(isLogin ? Icons.login : Icons.person_add,
                                  color: Colors.green),
                              const SizedBox(width: 8),
                              Text(
                                isLogin ? "Login" : "Sign Up",
                                style: const TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // ---------------- LOGIN ----------------
                          if (isLogin)
                            Form(
                              key: loginKey,
                              child: Column(
                                children: [
                                  TextFormField(
                                    decoration: _dec("Email", icon: Icons.email),
                                    keyboardType: TextInputType.emailAddress,
                                    onChanged: (v) => lEmail = v,
                                    validator: (v) =>
                                    v == null || !v.contains('@')
                                        ? "Enter a valid email"
                                        : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    decoration: _dec("Phone number (password)",
                                        icon: Icons.phone).copyWith(
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                            lObscure ? Icons.visibility : Icons.visibility_off),
                                        onPressed: () {
                                          lObscure = !lObscure;
                                          setLocal(() {});
                                        },
                                      ),
                                    ),
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly
                                    ],
                                    obscureText: lObscure,
                                    keyboardType: TextInputType.number,
                                    onChanged: (v) => lPhonePwd = v,
                                    validator: (v) =>
                                    v == null || v.length < 10
                                        ? "Enter 10-digit phone"
                                        : null,
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green,
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                            BorderRadius.circular(12)),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                      ),
                                      onPressed: lBusy ? null : doLogin,
                                      icon: lBusy
                                          ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white),
                                      )
                                          : const Icon(Icons.login,
                                          color: Colors.white),
                                      label: const Text("Login",
                                          style:
                                          TextStyle(color: Colors.white)),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextButton(
                                    onPressed: () {
                                      isLogin = false;
                                      setLocal(() {});
                                    },
                                    child: const Text("New here? Create an account"),
                                  ),
                                ],
                              ),
                            ),

                          // ---------------- SIGNUP ----------------
                          if (!isLogin)
                            Form(
                              key: signupKey,
                              child: Column(
                                children: [
                                  TextFormField(
                                    decoration: _dec("Full Name",
                                        icon: Icons.person),
                                    onChanged: (v) => sName = v,
                                    validator: (v) =>
                                    v == null || v.isEmpty ? "Enter name" : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    decoration: _dec("Email", icon: Icons.email),
                                    keyboardType: TextInputType.emailAddress,
                                    onChanged: (v) => sEmail = v,
                                    validator: (v) =>
                                    v == null || !v.contains('@')
                                        ? "Enter a valid email"
                                        : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    decoration: _dec("Phone number (password)",
                                        icon: Icons.phone).copyWith(
                                      suffixIcon: IconButton(
                                        icon: Icon(sObscure1
                                            ? Icons.visibility
                                            : Icons.visibility_off),
                                        onPressed: () {
                                          sObscure1 = !sObscure1;
                                          setLocal(() {});
                                        },
                                      ),
                                    ),
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly
                                    ],
                                    obscureText: sObscure1,
                                    keyboardType: TextInputType.number,
                                    onChanged: (v) => sPhonePwd = v,
                                    validator: (v) =>
                                    v == null || v.length < 10
                                        ? "Enter 10-digit phone"
                                        : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    decoration: _dec("Confirm phone number",
                                        icon: Icons.phone_iphone).copyWith(
                                      suffixIcon: IconButton(
                                        icon: Icon(sObscure2
                                            ? Icons.visibility
                                            : Icons.visibility_off),
                                        onPressed: () {
                                          sObscure2 = !sObscure2;
                                          setLocal(() {});
                                        },
                                      ),
                                    ),
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly
                                    ],
                                    obscureText: sObscure2,
                                    keyboardType: TextInputType.number,
                                    onChanged: (v) => sPhoneConfirm = v,
                                    validator: (v) {
                                      if (v == null || v.length < 10) {
                                        return "Enter 10-digit phone";
                                      }
                                      if (v != sPhonePwd) {
                                        return "Phone numbers do not match";
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green,
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                            BorderRadius.circular(12)),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                      ),
                                      onPressed: sBusy ? null : doSignup,
                                      icon: sBusy
                                          ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white),
                                      )
                                          : const Icon(Icons.person_add,
                                          color: Colors.white),
                                      label: const Text("Sign Up",
                                          style:
                                          TextStyle(color: Colors.white)),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextButton(
                                    onPressed: () {
                                      isLogin = true;
                                      setLocal(() {});
                                    },
                                    child: const Text("Already have an account? Log in"),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  _closeButton(),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Legacy wrappers to keep your existing calls working
  void showLoginDialog() => showAuthDialog(startInLogin: true);
  void showSignupDialog() => showAuthDialog(startInLogin: false);

  // ------------------------ BUILD ------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        title: Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                dropdownColor: Colors.white,
                value: selectedCity,
                hint:
                const Text("Select City", style: TextStyle(color: Colors.white)),
                isExpanded: true,
                underline: Container(),
                onChanged: (value) {
                  setState(() {
                    selectedCity = value!;
                    cacheSelectedCity(selectedCity!);
                    lastKey = null;
                    allShops.clear();
                    displayedShops.clear();
                    hasMore = true;
                  });
                  fetchShops(reset: true);
                },
                items: cities
                    .map((city) => DropdownMenuItem(
                  value: city,
                  child: Text(city,
                      style: const TextStyle(color: Colors.black)),
                ))
                    .toList(),
              ),
            ),
            const SizedBox(width: 10),
            if (currentUser == null) ...[
              TextButton(
                  onPressed: showLoginDialog,
                  child: const Text("Login",
                      style: TextStyle(color: Colors.white))),
              TextButton(
                  onPressed: showSignupDialog,
                  child: const Text("Signup",
                      style: TextStyle(color: Colors.white))),
            ] else ...[
              IconButton(
                icon: const Icon(Icons.receipt_long, color: Colors.white),
                tooltip: "My Orders",
                onPressed: () {
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const OrdersScreen()));
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text("Hi, ${userName ?? 'User'}",
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w500)),
              ),
            ],
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                hintText: "Search for shops...",
                prefixIcon: const Icon(Icons.search),
                border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: (v) {
                searchQuery = v;
                setState(() {
                  displayedShops = applySearch(allShops, searchQuery);
                });
              },
            ),
          ),
          Expanded(
            child: GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: .65,
              ),
              itemCount: displayedShops.length + (hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= displayedShops.length) {
                  return const Center(child: CircularProgressIndicator());
                }

                final shop = displayedShops[index];
                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProductListScreen(
                          city: selectedCity!,
                          shopId: shop["id"],
                          shopName: shop["name"],
                        ),
                      ),
                    );
                  },
                  child: Card(
                    elevation: 3,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(10)),
                            child: _buildBannerImage(shop['banner']),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            children: [
                              Text(
                                shop['name'],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style:
                                const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
