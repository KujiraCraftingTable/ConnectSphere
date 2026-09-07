const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const {
  listUsers, getUser, updateMe, createPersona, updateDefaultMode,
  blockUser, unblockUser, blockStatus, listBlocked, deleteMe,
} = require('../controllers/usersController');

// User list / profile can only be viewed while logged in
router.use(authMiddleware);

router.get('/',        listUsers);
router.patch('/me',    updateMe);        // must be registered before /:id
router.delete('/me',   deleteMe);        // must be registered before /:id
router.post('/me/personas', createPersona); // create the second mode's persona
router.patch('/me/default-mode', updateDefaultMode); // which mode the app opens in after login
router.get('/blocked', listBlocked);     // must be registered before /:id

router.post('/:id/block',   blockUser);
router.delete('/:id/block', unblockUser);
router.get('/:id/blocked',  blockStatus);

router.get('/:id',   getUser);

module.exports = router;
