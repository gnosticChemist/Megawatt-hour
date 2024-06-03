// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FunctionsRequest} from "@chainlink/contracts@1.1.0/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {FunctionsClient} from "@chainlink/contracts@1.1.0/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract SmartGrid is ConfirmedOwner, FunctionsClient, ERC20{
    using Strings for uint256;
    using FunctionsRequest for FunctionsRequest.Request;

    //  ------ FUNCTIONS VARIABLES ------
    address router = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0; //Sepolia Router
    bytes32 constant DON_ID = hex"66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000";
    uint32 constant GAS_LIMIT = 300000;
    uint64 immutable i_subId;
    mapping(bytes32 requestId => address target) private s_requests;
    string source = 
    "const apiResponse = await Functions.makeHttpRequest({"
            "url: `https://netzer0.app.br/api/v1/integrations/http/e2a81c53-e661-1b96-53eb-4d64ce520e8f`,"
            "method: 'POST',"
            "headers: {"
            "accept: 'application/json',"
        "},"
        "data: { deviceId: args[0], deviceType: 'DEVICE'}});"
    "if (apiResponse.error) {"
    "throw Error('Request failed');"
    "}"
    "const { data } = apiResponse;"
    "var value = parseInt(data.Exportacao.value);"
    "return Functions.encodeUint256(value);";

    //  ------ FUNCTIONS METHODS ------
    function sendRequest(
        uint256 deviceId
    ) internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source); // Initialize the request with JS code
        string[] memory args = new string[](1);
        args[0] = deviceId.toHexString();
        req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        bytes32 reqId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID);
        s_requests[reqId] = msg.sender;

        return reqId;
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*err*/) internal override{
        address target = s_requests[requestId];
        uint256 produced = uint256(bytes32(response));
        if(produced > producers[target].energyProduced){
            mint(target, produced - producers[target].energyProduced);
            producers[target].energyProduced = produced;
        }
    }
    //#######################

    //Represents a Power Plant
    struct Producer{
        uint256 deviceId;       //Smart Meter ID
        uint256 energyProduced; //Cumulative metric
    }
    mapping (address wallet => Producer producer) private producers;

    mapping (uint256 deviceId => address wallet) private consumers;

    //Linked list Structure
    struct Node{
        uint256 value;
        uint256 next;
    }
    mapping(address => mapping (uint256 => Node)) nodes;

    uint256 month = 0;

    constructor(uint64 subId)
        FunctionsClient(router)
        ConfirmedOwner(msg.sender)
        ERC20("MegaWattHour", "MWh")
    {
        i_subId = subId;
    }

    ///Registers a wallet to recive MWh Tokens from a power plant
    // Public for easier testing, would be onlyOwner otherwise
    function registerProducer(address walletProducer, uint256 deviceId) public {
        producers[walletProducer] = Producer(deviceId, 0);
    }

    // Public for easier testing, would be onlyOwner otherwise
    function registerProducer(address walletProducer, uint256 deviceId, uint256 startingValue) public{
        producers[walletProducer] = Producer(deviceId, startingValue);
    }

    /// Sings up a wallet to an Smart Meter, allowing NetZer0 to burn their tokens in order to discound consumed energy from this device
    function signupConsumer(uint256 deviceId) public{
        require(consumers[deviceId] == address(0), "Device currently claimed by a wallet");
        consumers[deviceId] = msg.sender;
    }
    /// Sings up a wallet to an Smart Meter, allowing NetZer0 to burn their tokens in order to discound consumed energy from this device
    function unsignConsumer(uint256 deviceId) public{
        require(consumers[deviceId] == msg.sender, "Device currently claimed by another wallet");
        consumers[deviceId] = address(0);
    }

    /// Fire a Functions request to collect energy production data and mint energy tokens
    function mintRequest(address to) public{
        require(producers[to].deviceId != 0);
        sendRequest(producers[to].deviceId);
    }

    /// Creates or Updates a Node on a linked list
    /// @param i - Owner of the linked list
    /// @param value - Token amount
    /// @param key - Expiration month
    function update(address i, uint256 value, uint256 key) internal{
        Node storage nav = nodes[i][0];
        uint256 current = 0;
        while(nav.next!= 0 && nav.next < key){
            current = nav.next;
            nav = nodes[i][nav.next];
        }

        if(nav.next == key){
            //Updates
            nodes[i][nav.next].value +=value;
        }else{
            //Creates
            nodes[i][key] = Node(value,nav.next);
            nav.next = key;
        }  
    }

    // Public for easier testing, would be internal otherwise
    function mint(address to, uint256 amount) public {
        update(to, amount,month+60);
        _mint(to, amount);
    }

    /// Burns expired tokens and updates the linked list
    function handleExpiration(address c) internal{
        Node storage nav = nodes[c][0];
        uint256 current = 0;
        uint256 burned = 0;
        while(nav.next!= 0 && nav.next < month){
            current = nav.next;
            nav = nodes[c][current];
            burned += nav.value;
        }
        current = nav.next;
        nodes[c][0].next = current;
        nav = nodes[c][current];

        _burn(c, burned);
    }

    /// Charges a consumer and burns their tokens
    /// @return Remainder of energy that couldn't be discounted (not enough tokens)
    function charge(address c, uint256 amount) public returns (uint256){
        Node storage nav = nodes[c][0];
        uint256 current = 0;
        uint256 burned = 0;
        while(nav.next!= 0 && nav.next < month){
            current = nav.next;
            nav = nodes[c][current];
            burned += nav.value;
        }
        
        current = nav.next;
        nodes[c][0].next = current;
        nav = nodes[c][current];

        while(amount >0){
            if(amount>nav.value){
                burned += nav.value;
                amount -= nav.value;
                nav.value = 0;
            }else{
                nav.value -= amount;
                burned += amount;
                amount = 0;
            }
            current = nav.next;
            if(current == 0)break;
            nav = nodes[c][nav.next];
        }
        _burn(c, burned);
        return amount;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(balanceOf(msg.sender) >= amount);
        handleExpiration(msg.sender);
        /*while(nav.next!= 0 && nav.next < month){
            current = nav.next;
            nav = nodes[msg.sender][current];
        }*/
        

        uint256 value = amount;

        Node storage nav = nodes[msg.sender][0];
        uint256 current = 0;
        current = nav.next;
        nodes[msg.sender][0].next = current;
        nav = nodes[msg.sender][current];

        while(amount >0){
            if(amount>nav.value){
                update(to, nav.value, current);
                amount -= nav.value;
                nav.value = 0;
            }else{
                nav.value -= amount;
                update(to, amount, current);
                amount = 0;
            }
            current = nav.next;
            nav = nodes[msg.sender][nav.next];
        }
        return ERC20.transfer(to, value);
    }

    function balanceOf(address account) public view override returns (uint256) {
        Node storage nav = nodes[account][0];
        uint256 current = 0;
        uint256 expired = 0;
        while(nav.next!= 0 && nav.next < month){
            current = nav.next;
            nav = nodes[account][nav.next];
            expired+= nav.value;
        }
        return ERC20.balanceOf(account)-expired;
    }

    /// Check the balance in a future month
    function futureBalanceOf(address account, uint256 _month) public view returns (uint256) {
        Node storage nav = nodes[account][0];
        uint256 current = 0;
        uint256 spoiled = 0;
        while(nav.next!= 0 && nav.next < _month){
            current = nav.next;
            nav = nodes[account][nav.next];
            spoiled+= nav.value;
        }
        return ERC20.balanceOf(account)-spoiled;
    }

    /// Returns the detailed balance of the account organized by the tokens remaining months
    function detailedBalanceOf(address account) public view returns (string memory){
        Node storage nav = nodes[account][0];
        uint256 current = nav.next;
        nav = nodes[account][nav.next];
        string memory result = "";
        while(current!= 0){
            result = string.concat(result, '(',Strings.toString(current-month),'m: ',Strings.toString(nav.value),' MWh)');
            current = nav.next;
            nav = nodes[account][nav.next];
        }
        return result;
    }



    function decimals() public view virtual override returns (uint8) {
        return 3;
    }

    function getProduced(address wallet) public view returns(uint256){
        return producers[wallet].energyProduced;
    }


    /// Only exists for testing
    function setMonth(uint256 _month) public{
        month = _month;
    }

    /// Called by Chainlink Automation, still need to be restricted so isn't public
    function incrementMonth() public{
        month = month+1;
    }
}