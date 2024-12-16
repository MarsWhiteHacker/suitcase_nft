// -create collection
// -admin can mint to someone
// -owner can burn
// -owner can transfer
// -has attributes
// -has royalty
// -change token uri
// -unit test
// -has events

module suitcase_nft_addr::suitcase_nft {
    use std::bcs;
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use std::option::{Self, Option};
    use aptos_token_objects::collection;
    use std::string::{Self, String, utf8};
    use aptos_token_objects::token::{Self, MutatorRef, BurnRef};
    use aptos_framework::object::{Self, ConstructorRef, Object, ObjectCore};
    use aptos_token_objects::property_map::{Self, MutatorRef as PropertyMutatorRef};
    use aptos_token_objects::royalty::{Self, MutatorRef as RoyaltyMutatorRef, Royalty};

    const E_NOT_OWNER: u64 = 1;
    const E_NOT_TOKEN_OWNER: u64 = 2;
    const E_ATTRIBUTES_WRONG_LENGTH: u64 = 3;

    const COLLECTION_NAME: vector<u8> = b"Suitcase NFT";
    const COLLECTION_URI: vector<u8> = b"uri placeholder";
    const COLLECTION_DESCRIPTION: vector<u8> = b"The best suitcases from Kovel";

    struct TokenRefs has key {
        burn_ref: BurnRef,
        mutator_ref: MutatorRef,
        property_mutator_ref: PropertyMutatorRef,
        royalty_mutator_ref: RoyaltyMutatorRef,
    }

    struct RoyaltyRef has key {
        royalty_mutator_ref: RoyaltyMutatorRef,
    }

    #[event]
    struct AddedAttribute has drop, store {
        token: address,
        key: String,
        value: vector<u8>,
    }

    #[event]
    struct RemovedAttribute has drop, store {
        token: address,
        key: String,
    }

    fun init_module(owner: &signer) {
        let collection_royalty = royalty::create(5, 100, signer::address_of(owner));

        let constructor_ref = collection::create_unlimited_collection(
            owner,
            utf8(COLLECTION_DESCRIPTION),
            utf8(COLLECTION_NAME),
            option::some(collection_royalty),
            utf8(COLLECTION_URI),
        );

        let collection_signer = object::generate_signer(&constructor_ref);
        let collections_extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(&collection_signer, RoyaltyRef {
            royalty_mutator_ref: royalty::generate_mutator_ref(collections_extend_ref),
        });
    }

    public entry fun mint(
        creator: &signer,
        to: address,
        name: String,
        uri: String,
        description: String,
        numerator: u64,
        denominator: u64,
        attributes_keys: vector<String>,
        attributes_values: vector<String>,
    ) {
        assert_is_owner(signer::address_of(creator));

        let length = vector::length(&attributes_keys);
        assert!(length == vector::length(&attributes_values), E_ATTRIBUTES_WRONG_LENGTH);

        let token_constructor_ref = token::create_named_token(
            creator,
            utf8(COLLECTION_NAME),
            description,
            name,
            option::some(royalty::create(numerator, denominator, @suitcase_nft_addr)),
            uri
        );

        let token_signer = object::generate_signer(&token_constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&token_constructor_ref);
        let extend_ref = object::generate_extend_ref(&token_constructor_ref);
        let mutator_ref = token::generate_mutator_ref(&token_constructor_ref);
        let burn_ref = token::generate_burn_ref(&token_constructor_ref);
        let property_mutator_ref = property_map::generate_mutator_ref(&token_constructor_ref);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&transfer_ref);
        let royalty_mutator_ref = royalty::generate_mutator_ref(extend_ref);

        object::transfer_with_ref(linear_transfer_ref, to);

        let properties = property_map::prepare_input(vector[], vector[], vector[]);
        property_map::init(&token_constructor_ref, properties);

        while(!vector::is_empty(&attributes_keys)){
            let key = vector::pop_back(&mut attributes_keys);
            let value = vector::pop_back(&mut attributes_values);

            property_map::add_typed(
                &property_mutator_ref,
                key,
                value
            );
        };

        move_to(&token_signer, TokenRefs {
            burn_ref,
            mutator_ref,
            royalty_mutator_ref,
            property_mutator_ref,
        });
    }

    public entry fun burn(creator: &signer, token: Object<ObjectCore>) acquires TokenRefs {
        assert_if_token_owner(signer::address_of(creator), token);

        let token_name = token::name(token);

        let TokenRefs {
            burn_ref,
            mutator_ref: _,
            royalty_mutator_ref: _,
            property_mutator_ref,
        } = move_from<TokenRefs>(token_address(token_name));

        property_map::burn(property_mutator_ref);

        token::burn(burn_ref);
    }

    public entry fun transfer(creator: &signer, token: Object<ObjectCore>, to: address) {
        assert_if_token_owner(signer::address_of(creator), token);

        object::transfer(creator, token, to);
    }

    public entry fun change_collection_royalty(creator: &signer, numerator: u64, denominator: u64) acquires RoyaltyRef {
        assert_is_owner(signer::address_of(creator));
        let royalty_mutator_ref = &borrow_global<RoyaltyRef>(collection_address()).royalty_mutator_ref;
        royalty::update(royalty_mutator_ref, royalty::create(numerator, denominator, signer::address_of(creator)));
    }

    public entry fun change_token_royalty(creator: &signer, token: Object<ObjectCore>, numerator: u64, denominator: u64) acquires TokenRefs {
        assert_if_token_owner(signer::address_of(creator), token);
        
        let token_name = token::name(token);
        let royalty_mutator_ref = &borrow_global<TokenRefs>(token_address(token_name)).royalty_mutator_ref;

        royalty::update(royalty_mutator_ref, royalty::create(numerator, denominator, @suitcase_nft_addr));
    }

    public entry fun add_attribute<T: drop + copy>(creator: &signer, token: Object<ObjectCore>, key: String, value: T) acquires TokenRefs {
        assert_if_token_owner(signer::address_of(creator), token);

        let token_name = token::name(token);
        let property_mutator_ref = &borrow_global<TokenRefs>(token_address(token_name)).property_mutator_ref;

        let value_copy = copy value;

        property_map::add_typed(
            property_mutator_ref,
            key,
            value
        );

        event::emit(AddedAttribute {
            token: object::object_address(&token),
            key,
            value: bcs::to_bytes(&value_copy),
        });
    }

    public entry fun remove_attribute(creator: &signer, token: Object<ObjectCore>, key: String) acquires TokenRefs {
        assert_if_token_owner(signer::address_of(creator), token);

        let token_name = token::name(token);
        let property_mutator_ref = &borrow_global<TokenRefs>(token_address(token_name)).property_mutator_ref;

        property_map::remove(property_mutator_ref, &key);

        event::emit(RemovedAttribute {
            token: object::object_address(&token),
            key,
        });
    }

    public entry fun change_token_uri(creator: &signer, token: Object<ObjectCore>, new_uri: String) acquires TokenRefs {
        assert_if_token_owner(signer::address_of(creator), token);

        let token_name = token::name(token);
        let mutator_ref = &borrow_global<TokenRefs>(token_address(token_name)).mutator_ref;

        token::set_uri(mutator_ref, new_uri);
    }

    #[view]
    public fun collection_address(): address {
        collection::create_collection_address(&@suitcase_nft_addr, &utf8(COLLECTION_NAME))
    }

    #[view]
    public fun token_address(token_name: String): address {
        token::create_token_address(&@suitcase_nft_addr, &utf8(COLLECTION_NAME), &token_name)
    }

    #[view]
    public fun token_royalty(token: Object<ObjectCore>): Option<Royalty> {
        token::royalty(token)
    }

    #[view]
    public fun token_uri(token: Object<ObjectCore>): String {
        token::uri(token)
    }

    fun assert_is_owner(user: address) {
        assert!(user == @suitcase_nft_addr, E_NOT_OWNER);
    }

    fun assert_if_token_owner(user: address, token: Object<ObjectCore>) {
        assert!(object::is_owner(token, user), E_NOT_TOKEN_OWNER);
    }



    #[test_only]
    use std::account;
    use aptos_token_objects::token::{Token};
    use aptos_token_objects::collection::{Collection};

    #[test_only]
    fun mint_default_token(creator: &signer, to: address) {
        mint(
            creator,
            to,
            utf8(b"TokenName"),
            utf8(b"TokenUri"),
            utf8(b"TokenDescription"),
            5,
            100,
            vector[utf8(b"Key1"), utf8(b"Key2")],
            vector[utf8(b"Value1"), utf8(b"Value2")],
        );
    }

    #[test(creator=@suitcase_nft_addr)]
    fun test_collection_created(creator: &signer) {
        init_module(creator);

        let collection_creator = collection::creator<Collection>(object::address_to_object(collection_address()));
        let collection_description = collection::description<Collection>(object::address_to_object(collection_address()));
        let collection_name = collection::name<Collection>(object::address_to_object(collection_address()));
        let collection_uri = collection::uri<Collection>(object::address_to_object(collection_address()));

        assert!(collection_creator == signer::address_of(creator), 1);
        assert!(collection_description == utf8(COLLECTION_DESCRIPTION), 2);
        assert!(collection_name == utf8(COLLECTION_NAME), 3);
        assert!(collection_uri == utf8(COLLECTION_URI), 4);

        let royalty = royalty::get<Collection>(object::address_to_object(collection_address()));

        let royalty_numerator = royalty::numerator(option::borrow(&royalty));
        let royalty_denominator = royalty::denominator(option::borrow(&royalty));
        let royalty_payee_address = royalty::payee_address(option::borrow(&royalty));

        assert!(royalty_numerator == 5, 5);
        assert!(royalty_denominator == 100, 6);
        assert!(royalty_payee_address == signer::address_of(creator), 7);
    }

    #[test(creator=@suitcase_nft_addr)]
    fun test_mint(creator: &signer) {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint(
            creator,
            aaron_address,
            utf8(b"TokenName"),
            utf8(b"TokenUri"),
            utf8(b"TokenDescription"),
            5,
            100,
            vector[utf8(b"Key1"), utf8(b"Key2")],
            vector[utf8(b"Value1"), utf8(b"Value2")],
        );

        let token_object = object::address_to_object(token_address(utf8(b"TokenName")));

        let token_creator = token::creator<Token>(token_object);
        let token_name = token::name<Token>(token_object);
        let token_description = token::description<Token>(token_object);
        let token_uri = token::uri<Token>(token_object);
        let token_royalty = token::royalty<Token>(token_object);
        let token_index = token::index<Token>(token_object);
        let token_owner = object::owner(token_object);

        let royalty_numerator = royalty::numerator(option::borrow(&token_royalty));
        let royalty_denominator = royalty::denominator(option::borrow(&token_royalty));
        let royalty_payee_address = royalty::payee_address(option::borrow(&token_royalty));

        let attributes_length = property_map::length(&token_object);
        let attributes_value1 = property_map::read_string(&token_object, &utf8(b"Key1"));
        let attributes_value2 = property_map::read_string(&token_object, &utf8(b"Key2"));

        assert!(token_creator == creator_address, 8);
        assert!(token_name == utf8(b"TokenName"), 9);
        assert!(token_uri == utf8(b"TokenUri"), 10);
        assert!(token_description == utf8(b"TokenDescription"), 11);
        assert!(token_index == 1, 12);
        assert!(token_owner == aaron_address, 13);
        assert!(royalty_numerator == 5, 14);
        assert!(royalty_denominator == 100, 15);
        assert!(royalty_payee_address == creator_address, 16);
        assert!(attributes_length == 2, 17);
        assert!(attributes_value1 == utf8(b"Value1"), 18);
        assert!(attributes_value2 == utf8(b"Value2"), 19);
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_NOT_OWNER)]
    fun test_mint_not_owner(creator: &signer) {
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint(
            &aaron,
            aaron_address,
            utf8(b"TokenName"),
            utf8(b"TokenUri"),
            utf8(b"TokenDescription"),
            5,
            100,
            vector[utf8(b"Key1"), utf8(b"Key2")],
            vector[utf8(b"Value1"), utf8(b"Value2")],
        );
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_ATTRIBUTES_WRONG_LENGTH)]
    fun test_mint_wrong_attributes_length(creator: &signer) {
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint(
            creator,
            aaron_address,
            utf8(b"TokenName"),
            utf8(b"TokenUri"),
            utf8(b"TokenDescription"),
            5,
            100,
            vector[utf8(b"Key1")],
            vector[utf8(b"Value1"), utf8(b"Value2")],
        );
    }

    #[test(creator=@suitcase_nft_addr)]
    fun test_burn(creator: &signer) acquires TokenRefs {
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object(token_address(utf8(b"TokenName")));

        let collection_count = collection::count<Collection>(object::address_to_object(collection_address()));
        assert!(option::extract(&mut collection_count) == 1, 20);

        burn(&aaron, token_object);

        let collection_count_after = collection::count<Collection>(object::address_to_object(collection_address()));
        assert!(option::extract(&mut collection_count_after) == 0, 21);
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_NOT_TOKEN_OWNER)]
    fun test_burn_not_owner(creator: &signer) acquires TokenRefs {
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object(token_address(utf8(b"TokenName")));

        burn(creator, token_object);
    }

    #[test(creator=@suitcase_nft_addr)]
    fun test_transfer(creator: &signer) {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object<Token>(token_address(utf8(b"TokenName")));

        assert!(object::is_owner(token_object, aaron_address), 22);

        transfer(&aaron, object::convert<Token, ObjectCore>(token_object), creator_address);

        assert!(object::is_owner(token_object, creator_address), 23);
        assert!(!object::is_owner(token_object, aaron_address), 24);
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_NOT_TOKEN_OWNER)]
    fun test_transfer_not_owner(creator: &signer) {
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object<Token>(token_address(utf8(b"TokenName")));

        transfer(creator, object::convert<Token, ObjectCore>(token_object), aaron_address);
    }

    #[test(creator=@suitcase_nft_addr)]
    fun test_change_collection_royalty(creator: &signer) acquires RoyaltyRef {
        init_module(creator);

        let royalty = royalty::get<Collection>(object::address_to_object(collection_address()));

        let royalty_numerator = royalty::numerator(option::borrow(&royalty));
        let royalty_denominator = royalty::denominator(option::borrow(&royalty));
        let royalty_payee_address = royalty::payee_address(option::borrow(&royalty));

        assert!(royalty_numerator == 5, 25);
        assert!(royalty_denominator == 100, 26);
        assert!(royalty_payee_address == signer::address_of(creator), 27);

        change_collection_royalty(creator, 10, 200);

        let royalty_after = royalty::get<Collection>(object::address_to_object(collection_address()));

        let royalty_numerator_after = royalty::numerator(option::borrow(&royalty_after));
        let royalty_denominator_after = royalty::denominator(option::borrow(&royalty_after));
        let royalty_payee_address_after = royalty::payee_address(option::borrow(&royalty_after));

        assert!(royalty_numerator_after == 10, 28);
        assert!(royalty_denominator_after == 200, 29);
        assert!(royalty_payee_address == signer::address_of(creator), 30);
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_NOT_OWNER)]
    fun test_change_collection_royalty_not_owner(creator: &signer) acquires RoyaltyRef {
        let aaron = account::create_signer_for_test(@0x1);

        init_module(creator);

        let royalty = royalty::get<Collection>(object::address_to_object(collection_address()));

        change_collection_royalty(&aaron, 10, 200);
    }

    #[test(creator=@suitcase_nft_addr)]
    fun test_change_token_royalty(creator: &signer) acquires TokenRefs {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object(token_address(utf8(b"TokenName")));

        let token_royalty = token::royalty<Token>(token_object);

        let royalty_numerator = royalty::numerator(option::borrow(&token_royalty));
        let royalty_denominator = royalty::denominator(option::borrow(&token_royalty));
        let royalty_payee_address = royalty::payee_address(option::borrow(&token_royalty));

        assert!(royalty_numerator == 5, 31);
        assert!(royalty_denominator == 100, 32);
        assert!(royalty_payee_address == creator_address, 33);

        change_token_royalty(&aaron, object::convert<Token, ObjectCore>(token_object), 10, 200);

        let token_royalty_after = token::royalty<Token>(token_object);

        let royalty_numerator_after = royalty::numerator(option::borrow(&token_royalty_after));
        let royalty_denominator_after = royalty::denominator(option::borrow(&token_royalty_after));
        let royalty_payee_address_after = royalty::payee_address(option::borrow(&token_royalty_after));

        assert!(royalty_numerator_after == 10, 34);
        assert!(royalty_denominator_after == 200, 35);
        assert!(royalty_payee_address_after == creator_address, 36);
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_NOT_TOKEN_OWNER)]
    fun test_change_token_royalty_not_owner(creator: &signer) acquires TokenRefs {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object(token_address(utf8(b"TokenName")));

        change_token_royalty(creator, object::convert<Token, ObjectCore>(token_object), 10, 200);
    }   

    #[test(creator=@suitcase_nft_addr)]
    fun test_change_token_uri(creator: &signer) acquires TokenRefs {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object(token_address(utf8(b"TokenName")));

        let token_uri = token::uri<Token>(token_object);

        assert!(token_uri == utf8(b"TokenUri"), 37);

        change_token_uri(&aaron, object::convert<Token, ObjectCore>(token_object), utf8(b"New Uri"));

        let token_uri_after = token::uri<Token>(token_object);

        assert!(token_uri_after == utf8(b"New Uri"), 38);
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_NOT_TOKEN_OWNER)]
    fun test_change_token_uri_not_owner(creator: &signer) acquires TokenRefs {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object(token_address(utf8(b"TokenName")));

        change_token_uri(creator, object::convert<Token, ObjectCore>(token_object), utf8(b"New Uri"));
    }

    #[test(creator=@suitcase_nft_addr)]
    fun test_add_attribute(creator: &signer) acquires TokenRefs {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object<Token>(token_address(utf8(b"TokenName")));

        let attributes_length = property_map::length(&token_object);
        let attributes_value1 = property_map::read_string(&token_object, &utf8(b"Key1"));
        let attributes_value2 = property_map::read_string(&token_object, &utf8(b"Key2"));

        assert!(attributes_length == 2, 39);
        assert!(attributes_value1 == utf8(b"Value1"), 40);
        assert!(attributes_value2 == utf8(b"Value2"), 41);

        add_attribute(&aaron, object::convert<Token, ObjectCore>(token_object), utf8(b"Key3"), utf8(b"Value3"));

        let attributes_length_after = property_map::length(&token_object);
        let attributes_value3 = property_map::read_string(&token_object, &utf8(b"Key3"));

        assert!(attributes_length_after == 3, 42);
        assert!(attributes_value3 == utf8(b"Value3"), 43);
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_NOT_TOKEN_OWNER)]
    fun test_add_attribute_not_owner(creator: &signer) acquires TokenRefs {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object<Token>(token_address(utf8(b"TokenName")));

        add_attribute(creator, object::convert<Token, ObjectCore>(token_object), utf8(b"Key3"), utf8(b"Value3"));
    }

    #[test(creator=@suitcase_nft_addr)]
    fun test_remove_attribute(creator: &signer) acquires TokenRefs {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object<Token>(token_address(utf8(b"TokenName")));

        let attributes_length = property_map::length(&token_object);
        let attributes_value1 = property_map::read_string(&token_object, &utf8(b"Key1"));
        let attributes_value2 = property_map::read_string(&token_object, &utf8(b"Key2"));

        assert!(attributes_length == 2, 44);
        assert!(attributes_value1 == utf8(b"Value1"), 45);
        assert!(attributes_value2 == utf8(b"Value2"), 46);

        remove_attribute(&aaron, object::convert<Token, ObjectCore>(token_object), utf8(b"Key2"));

        let attributes_length_after = property_map::length(&token_object);

        assert!(attributes_length_after == 1, 47);
        assert!(!property_map::contains_key(&token_object, &utf8(b"Key2")), 48);
    }

    #[test(creator=@suitcase_nft_addr)]
    #[expected_failure(abort_code = E_NOT_TOKEN_OWNER)]
    fun test_remove_attribute_not_owner(creator: &signer) acquires TokenRefs {
        let creator_address = signer::address_of(creator);
        let aaron = account::create_signer_for_test(@0x1);
        let aaron_address = signer::address_of(&aaron);

        init_module(creator);
        mint_default_token(creator, aaron_address);

        let token_object = object::address_to_object<Token>(token_address(utf8(b"TokenName")));

        remove_attribute(creator, object::convert<Token, ObjectCore>(token_object), utf8(b"Key2"));
    }
}
